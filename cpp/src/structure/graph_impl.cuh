/*
 * Copyright (c) 2020-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <cugraph/detail/decompress_matrix_partition.cuh>
#include <cugraph/detail/graph_utils.cuh>
#include <cugraph/detail/shuffle_wrappers.hpp>
#include <cugraph/graph.hpp>
#include <cugraph/graph_functions.hpp>
#include <cugraph/partition_manager.hpp>
#include <cugraph/utilities/error.hpp>
#include <cugraph/utilities/host_scalar_comm.cuh>

#include <raft/device_atomics.cuh>
#include <raft/handle.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/adjacent_difference.h>
#include <thrust/binary_search.h>
#include <thrust/equal.h>
#include <thrust/fill.h>
#include <thrust/for_each.h>
#include <thrust/gather.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/tuple.h>

#include <algorithm>
#include <tuple>

namespace cugraph {

namespace {

// can't use lambda due to nvcc limitations (The enclosing parent function ("graph_t") for an
// extended __device__ lambda must allow its address to be taken)
template <typename vertex_t>
struct out_of_range_t {
  vertex_t major_first{};
  vertex_t major_last{};
  vertex_t minor_first{};
  vertex_t minor_last{};

  __device__ bool operator()(thrust::tuple<vertex_t, vertex_t> t) const
  {
    auto major = thrust::get<0>(t);
    auto minor = thrust::get<1>(t);
    return (major < major_first) || (major >= major_last) || (minor < minor_first) ||
           (minor >= minor_last);
  }
};

// can't use lambda due to nvcc limitations (The enclosing parent function ("graph_t") for an
// extended __device__ lambda must allow its address to be taken)
template <typename vertex_t, typename edge_t>
struct has_nzd_t {
  edge_t const* offsets{nullptr};
  vertex_t major_first{};

  __device__ bool operator()(vertex_t major) const
  {
    auto major_offset = major - major_first;
    return offsets[major_offset + 1] - offsets[major_offset] > 0;
  }
};

// can't use lambda due to nvcc limitations (The enclosing parent function ("graph_t") for an
// extended __device__ lambda must allow its address to be taken)
template <typename edge_t>
struct rebase_offset_t {
  edge_t base_offset{};
  __device__ edge_t operator()(edge_t offset) const { return offset - base_offset; }
};

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
bool check_symmetric(raft::handle_t const& handle,
                     std::vector<edgelist_t<vertex_t, edge_t, weight_t>> const& edgelists)
{
  size_t number_of_local_edges{0};
  for (size_t i = 0; i < edgelists.size(); ++i) {
    number_of_local_edges += edgelists[i].number_of_edges;
  }

  auto is_weighted = edgelists[0].p_edge_weights.has_value();

  rmm::device_uvector<vertex_t> org_rows(number_of_local_edges, handle.get_stream());
  rmm::device_uvector<vertex_t> org_cols(number_of_local_edges, handle.get_stream());
  auto org_weights = is_weighted ? std::make_optional<rmm::device_uvector<weight_t>>(
                                     number_of_local_edges, handle.get_stream())
                                 : std::nullopt;
  size_t offset{0};
  for (size_t i = 0; i < edgelists.size(); ++i) {
    thrust::copy(handle.get_thrust_policy(),
                 edgelists[i].p_src_vertices,
                 edgelists[i].p_src_vertices + edgelists[i].number_of_edges,
                 org_rows.begin() + offset);
    thrust::copy(handle.get_thrust_policy(),
                 edgelists[i].p_dst_vertices,
                 edgelists[i].p_dst_vertices + edgelists[i].number_of_edges,
                 org_cols.begin() + offset);
    if (is_weighted) {
      thrust::copy(handle.get_thrust_policy(),
                   *(edgelists[i].p_edge_weights),
                   *(edgelists[i].p_edge_weights) + edgelists[i].number_of_edges,
                   (*org_weights).begin() + offset);
    }
    offset += edgelists[i].number_of_edges;
  }
  if constexpr (multi_gpu) {
    std::tie(
      store_transposed ? org_cols : org_rows, store_transposed ? org_rows : org_cols, org_weights) =
      detail::shuffle_edgelist_by_gpu_id(handle,
                                         std::move(store_transposed ? org_cols : org_rows),
                                         std::move(store_transposed ? org_rows : org_cols),
                                         std::move(org_weights));
  }

  rmm::device_uvector<vertex_t> symmetrized_rows(org_rows.size(), handle.get_stream());
  rmm::device_uvector<vertex_t> symmetrized_cols(org_cols.size(), handle.get_stream());
  auto symmetrized_weights = org_weights ? std::make_optional<rmm::device_uvector<weight_t>>(
                                             (*org_weights).size(), handle.get_stream())
                                         : std::nullopt;
  thrust::copy(
    handle.get_thrust_policy(), org_rows.begin(), org_rows.end(), symmetrized_rows.begin());
  thrust::copy(
    handle.get_thrust_policy(), org_cols.begin(), org_cols.end(), symmetrized_cols.begin());
  if (org_weights) {
    thrust::copy(handle.get_thrust_policy(),
                 (*org_weights).begin(),
                 (*org_weights).end(),
                 (*symmetrized_weights).begin());
  }
  std::tie(symmetrized_rows, symmetrized_cols, symmetrized_weights) =
    symmetrize_edgelist<vertex_t, weight_t, store_transposed, multi_gpu>(
      handle,
      std::move(symmetrized_rows),
      std::move(symmetrized_cols),
      std::move(symmetrized_weights),
      true);

  if (org_rows.size() != symmetrized_rows.size()) { return false; }

  if (org_weights) {
    auto org_edge_first = thrust::make_zip_iterator(
      thrust::make_tuple(org_rows.begin(), org_cols.begin(), (*org_weights).begin()));
    thrust::sort(handle.get_thrust_policy(), org_edge_first, org_edge_first + org_rows.size());
    auto symmetrized_edge_first = thrust::make_zip_iterator(thrust::make_tuple(
      symmetrized_rows.begin(), symmetrized_cols.begin(), (*symmetrized_weights).begin()));
    thrust::sort(handle.get_thrust_policy(),
                 symmetrized_edge_first,
                 symmetrized_edge_first + symmetrized_rows.size());

    return thrust::equal(handle.get_thrust_policy(),
                         org_edge_first,
                         org_edge_first + org_rows.size(),
                         symmetrized_edge_first);
  } else {
    auto org_edge_first =
      thrust::make_zip_iterator(thrust::make_tuple(org_rows.begin(), org_cols.begin()));
    thrust::sort(handle.get_thrust_policy(), org_edge_first, org_edge_first + org_rows.size());
    auto symmetrized_edge_first = thrust::make_zip_iterator(
      thrust::make_tuple(symmetrized_rows.begin(), symmetrized_cols.begin()));
    thrust::sort(handle.get_thrust_policy(),
                 symmetrized_edge_first,
                 symmetrized_edge_first + symmetrized_rows.size());

    return thrust::equal(handle.get_thrust_policy(),
                         org_edge_first,
                         org_edge_first + org_rows.size(),
                         symmetrized_edge_first);
  }
}

template <typename vertex_t, typename edge_t, typename weight_t>
bool check_no_parallel_edge(raft::handle_t const& handle,
                            std::vector<edgelist_t<vertex_t, edge_t, weight_t>> const& edgelists)
{
  size_t number_of_local_edges{0};
  for (size_t i = 0; i < edgelists.size(); ++i) {
    number_of_local_edges += edgelists[i].number_of_edges;
  }

  auto is_weighted = edgelists[0].p_edge_weights.has_value();

  rmm::device_uvector<vertex_t> edgelist_rows(number_of_local_edges, handle.get_stream());
  rmm::device_uvector<vertex_t> edgelist_cols(number_of_local_edges, handle.get_stream());
  auto edgelist_weights = is_weighted ? std::make_optional<rmm::device_uvector<weight_t>>(
                                          number_of_local_edges, handle.get_stream())
                                      : std::nullopt;
  size_t offset{0};
  for (size_t i = 0; i < edgelists.size(); ++i) {
    thrust::copy(handle.get_thrust_policy(),
                 edgelists[i].p_src_vertices,
                 edgelists[i].p_src_vertices + edgelists[i].number_of_edges,
                 edgelist_rows.begin() + offset);
    thrust::copy(handle.get_thrust_policy(),
                 edgelists[i].p_dst_vertices,
                 edgelists[i].p_dst_vertices + edgelists[i].number_of_edges,
                 edgelist_cols.begin() + offset);
    if (is_weighted) {
      thrust::copy(handle.get_thrust_policy(),
                   *(edgelists[i].p_edge_weights),
                   *(edgelists[i].p_edge_weights) + edgelists[i].number_of_edges,
                   (*edgelist_weights).begin() + offset);
    }
    offset += edgelists[i].number_of_edges;
  }

  if (edgelist_weights) {
    auto edge_first = thrust::make_zip_iterator(thrust::make_tuple(
      edgelist_rows.begin(), edgelist_cols.begin(), (*edgelist_weights).begin()));
    thrust::sort(handle.get_thrust_policy(), edge_first, edge_first + edgelist_rows.size());
    return thrust::unique(handle.get_thrust_policy(),
                          edge_first,
                          edge_first + edgelist_rows.size()) == (edge_first + edgelist_rows.size());
  } else {
    auto edge_first =
      thrust::make_zip_iterator(thrust::make_tuple(edgelist_rows.begin(), edgelist_cols.begin()));
    thrust::sort(handle.get_thrust_policy(), edge_first, edge_first + edgelist_rows.size());
    return thrust::unique(handle.get_thrust_policy(),
                          edge_first,
                          edge_first + edgelist_rows.size()) == (edge_first + edgelist_rows.size());
  }
}

// compress edge list (COO) to CSR (or CSC) or CSR + DCSR (CSC + DCSC) hybrid
template <bool store_transposed, typename vertex_t, typename edge_t, typename weight_t>
std::tuple<rmm::device_uvector<edge_t>,
           rmm::device_uvector<vertex_t>,
           std::optional<rmm::device_uvector<weight_t>>,
           std::optional<rmm::device_uvector<vertex_t>>>
compress_edgelist(edgelist_t<vertex_t, edge_t, weight_t> const& edgelist,
                  vertex_t major_first,
                  std::optional<vertex_t> major_hypersparse_first,
                  vertex_t major_last,
                  vertex_t /* minor_first */,
                  vertex_t /* minor_last */,
                  rmm::cuda_stream_view stream_view)
{
  rmm::device_uvector<edge_t> offsets((major_last - major_first) + 1, stream_view);
  rmm::device_uvector<vertex_t> indices(edgelist.number_of_edges, stream_view);
  auto weights = edgelist.p_edge_weights ? std::make_optional<rmm::device_uvector<weight_t>>(
                                             edgelist.number_of_edges, stream_view)
                                         : std::nullopt;
  thrust::fill(rmm::exec_policy(stream_view), offsets.begin(), offsets.end(), edge_t{0});
  thrust::fill(rmm::exec_policy(stream_view), indices.begin(), indices.end(), vertex_t{0});

  auto p_offsets = offsets.data();
  thrust::for_each(rmm::exec_policy(stream_view),
                   store_transposed ? edgelist.p_dst_vertices : edgelist.p_src_vertices,
                   store_transposed ? edgelist.p_dst_vertices + edgelist.number_of_edges
                                    : edgelist.p_src_vertices + edgelist.number_of_edges,
                   [p_offsets, major_first] __device__(auto v) {
                     atomicAdd(p_offsets + (v - major_first), edge_t{1});
                   });
  thrust::exclusive_scan(
    rmm::exec_policy(stream_view), offsets.begin(), offsets.end(), offsets.begin());

  auto p_indices = indices.data();
  if (edgelist.p_edge_weights) {
    auto p_weights = (*weights).data();

    auto edge_first = thrust::make_zip_iterator(thrust::make_tuple(
      edgelist.p_src_vertices, edgelist.p_dst_vertices, *(edgelist.p_edge_weights)));
    thrust::for_each(rmm::exec_policy(stream_view),
                     edge_first,
                     edge_first + edgelist.number_of_edges,
                     [p_offsets, p_indices, p_weights, major_first] __device__(auto e) {
                       auto s      = thrust::get<0>(e);
                       auto d      = thrust::get<1>(e);
                       auto w      = thrust::get<2>(e);
                       auto major  = store_transposed ? d : s;
                       auto minor  = store_transposed ? s : d;
                       auto start  = p_offsets[major - major_first];
                       auto degree = p_offsets[(major - major_first) + 1] - start;
                       auto idx    = atomicAdd(p_indices + (start + degree - 1),
                                            vertex_t{1});  // use the last element as a counter
                       // FIXME: we can actually store minor - minor_first instead of minor to save
                       // memory if minor can be larger than 32 bit but minor - minor_first fits
                       // within 32 bit
                       p_indices[start + idx] =
                         minor;  // overwrite the counter only if idx == degree - 1 (no race)
                       p_weights[start + idx] = w;
                     });
  } else {
    auto edge_first = thrust::make_zip_iterator(
      thrust::make_tuple(edgelist.p_src_vertices, edgelist.p_dst_vertices));
    thrust::for_each(rmm::exec_policy(stream_view),
                     edge_first,
                     edge_first + edgelist.number_of_edges,
                     [p_offsets, p_indices, major_first] __device__(auto e) {
                       auto s      = thrust::get<0>(e);
                       auto d      = thrust::get<1>(e);
                       auto major  = store_transposed ? d : s;
                       auto minor  = store_transposed ? s : d;
                       auto start  = p_offsets[major - major_first];
                       auto degree = p_offsets[(major - major_first) + 1] - start;
                       auto idx    = atomicAdd(p_indices + (start + degree - 1),
                                            vertex_t{1});  // use the last element as a counter
                       // FIXME: we can actually store minor - minor_first instead of minor to save
                       // memory if minor can be larger than 32 bit but minor - minor_first fits
                       // within 32 bit
                       p_indices[start + idx] =
                         minor;  // overwrite the counter only if idx == degree - 1 (no race)
                     });
  }

  auto dcs_nzd_vertices = major_hypersparse_first
                            ? std::make_optional<rmm::device_uvector<vertex_t>>(
                                major_last - *major_hypersparse_first, stream_view)
                            : std::nullopt;
  if (dcs_nzd_vertices) {
    auto constexpr invalid_vertex = invalid_vertex_id<vertex_t>::value;

    thrust::transform(
      rmm::exec_policy(stream_view),
      thrust::make_counting_iterator(*major_hypersparse_first),
      thrust::make_counting_iterator(major_last),
      (*dcs_nzd_vertices).begin(),
      [major_first, offsets = offsets.data()] __device__(auto major) {
        auto major_offset = major - major_first;
        return offsets[major_offset + 1] - offsets[major_offset] > 0 ? major : invalid_vertex;
      });

    auto pair_first = thrust::make_zip_iterator(thrust::make_tuple(
      (*dcs_nzd_vertices).begin(), offsets.begin() + (*major_hypersparse_first - major_first)));
    (*dcs_nzd_vertices)
      .resize(thrust::distance(pair_first,
                               thrust::remove_if(rmm::exec_policy(stream_view),
                                                 pair_first,
                                                 pair_first + (*dcs_nzd_vertices).size(),
                                                 [] __device__(auto pair) {
                                                   return thrust::get<0>(pair) == invalid_vertex;
                                                 })),
              stream_view);
    (*dcs_nzd_vertices).shrink_to_fit(stream_view);
    if (static_cast<vertex_t>((*dcs_nzd_vertices).size()) < major_last - *major_hypersparse_first) {
      thrust::copy(
        rmm::exec_policy(stream_view),
        offsets.begin() + (major_last - major_first),
        offsets.end(),
        offsets.begin() + (*major_hypersparse_first - major_first) + (*dcs_nzd_vertices).size());
      offsets.resize((*major_hypersparse_first - major_first) + (*dcs_nzd_vertices).size() + 1,
                     stream_view);
      offsets.shrink_to_fit(stream_view);
    }
  }

  return std::make_tuple(
    std::move(offsets), std::move(indices), std::move(weights), std::move(dcs_nzd_vertices));
}

template <typename vertex_t, typename edge_t, typename weight_t>
void sort_adjacency_list(raft::handle_t const& handle,
                         edge_t const* offsets,
                         vertex_t* indices /* [INOUT} */,
                         std::optional<weight_t*> weights /* [INOUT] */,
                         vertex_t num_vertices,
                         edge_t num_edges)
{
  // FIXME: The current cub's segmented sort based implementation is slower than the global sort
  // based approach, but we expect cub's segmented sort performance will get significantly better in
  // few months. We also need to re-evaluate performance & memory overhead of presorting edge list
  // and running thrust::reduce to update offset vs the current approach after updating the python
  // interface. If we take r-values of rmm::device_uvector edge list, we can do indcies_ =
  // std::move(minors) & weights_ = std::move (weights). This affects peak memory use and we may
  // find the presorting approach more attractive under this scenario.

  // 1. Check if there is anything to sort

  if (num_edges == 0) { return; }

  // 2. We segmented sort edges in chunks, and we need to adjust chunk offsets as we need to sort
  // each vertex's neighbors at once.

  // to limit memory footprint ((1 << 20) is a tuning parameter)
  auto approx_edges_to_sort_per_iteration =
    static_cast<size_t>(handle.get_device_properties().multiProcessorCount) * (1 << 20);
  auto search_offset_first =
    thrust::make_transform_iterator(thrust::make_counting_iterator(size_t{1}),
                                    [approx_edges_to_sort_per_iteration] __device__(auto i) {
                                      return i * approx_edges_to_sort_per_iteration;
                                    });
  auto num_chunks =
    (num_edges + approx_edges_to_sort_per_iteration - 1) / approx_edges_to_sort_per_iteration;
  rmm::device_uvector<vertex_t> d_vertex_offsets(num_chunks - 1, handle.get_stream());
  thrust::lower_bound(handle.get_thrust_policy(),
                      offsets,
                      offsets + num_vertices + 1,
                      search_offset_first,
                      search_offset_first + d_vertex_offsets.size(),
                      d_vertex_offsets.begin());
  rmm::device_uvector<edge_t> d_edge_offsets(d_vertex_offsets.size(), handle.get_stream());
  thrust::gather(handle.get_thrust_policy(),
                 d_vertex_offsets.begin(),
                 d_vertex_offsets.end(),
                 offsets,
                 d_edge_offsets.begin());
  std::vector<edge_t> h_edge_offsets(num_chunks + 1, edge_t{0});
  h_edge_offsets.back() = num_edges;
  raft::update_host(
    h_edge_offsets.data() + 1, d_edge_offsets.data(), d_edge_offsets.size(), handle.get_stream());
  std::vector<vertex_t> h_vertex_offsets(num_chunks + 1, vertex_t{0});
  h_vertex_offsets.back() = num_vertices;
  raft::update_host(h_vertex_offsets.data() + 1,
                    d_vertex_offsets.data(),
                    d_vertex_offsets.size(),
                    handle.get_stream());

  // 3. Segmented sort each vertex's neighbors

  size_t max_chunk_size{0};
  for (size_t i = 0; i < num_chunks; ++i) {
    max_chunk_size =
      std::max(max_chunk_size, static_cast<size_t>(h_edge_offsets[i + 1] - h_edge_offsets[i]));
  }
  rmm::device_uvector<vertex_t> segment_sorted_indices(max_chunk_size, handle.get_stream());
  auto segment_sorted_weights =
    weights ? std::make_optional<rmm::device_uvector<weight_t>>(max_chunk_size, handle.get_stream())
            : std::nullopt;
  rmm::device_uvector<std::byte> d_temp_storage(0, handle.get_stream());
  for (size_t i = 0; i < num_chunks; ++i) {
    size_t temp_storage_bytes{0};
    auto offset_first = thrust::make_transform_iterator(offsets + h_vertex_offsets[i],
                                                        rebase_offset_t<edge_t>{h_edge_offsets[i]});
    if (weights) {
      cub::DeviceSegmentedRadixSort::SortPairs(static_cast<void*>(nullptr),
                                               temp_storage_bytes,
                                               indices + h_edge_offsets[i],
                                               segment_sorted_indices.data(),
                                               (*weights) + h_edge_offsets[i],
                                               (*segment_sorted_weights).data(),
                                               h_edge_offsets[i + 1] - h_edge_offsets[i],
                                               h_vertex_offsets[i + 1] - h_vertex_offsets[i],
                                               offset_first,
                                               offset_first + 1,
                                               0,
                                               sizeof(vertex_t) * 8,
                                               handle.get_stream());
    } else {
      cub::DeviceSegmentedRadixSort::SortKeys(static_cast<void*>(nullptr),
                                              temp_storage_bytes,
                                              indices + h_edge_offsets[i],
                                              segment_sorted_indices.data(),
                                              h_edge_offsets[i + 1] - h_edge_offsets[i],
                                              h_vertex_offsets[i + 1] - h_vertex_offsets[i],
                                              offset_first,
                                              offset_first + 1,
                                              0,
                                              sizeof(vertex_t) * 8,
                                              handle.get_stream());
    }
    if (temp_storage_bytes > d_temp_storage.size()) {
      d_temp_storage = rmm::device_uvector<std::byte>(temp_storage_bytes, handle.get_stream());
    }
    if (weights) {
      cub::DeviceSegmentedRadixSort::SortPairs(d_temp_storage.data(),
                                               temp_storage_bytes,
                                               indices + h_edge_offsets[i],
                                               segment_sorted_indices.data(),
                                               (*weights) + h_edge_offsets[i],
                                               (*segment_sorted_weights).data(),
                                               h_edge_offsets[i + 1] - h_edge_offsets[i],
                                               h_vertex_offsets[i + 1] - h_vertex_offsets[i],
                                               offset_first,
                                               offset_first + 1,
                                               0,
                                               sizeof(vertex_t) * 8,
                                               handle.get_stream());
    } else {
      cub::DeviceSegmentedRadixSort::SortKeys(d_temp_storage.data(),
                                              temp_storage_bytes,
                                              indices + h_edge_offsets[i],
                                              segment_sorted_indices.data(),
                                              h_edge_offsets[i + 1] - h_edge_offsets[i],
                                              h_vertex_offsets[i + 1] - h_vertex_offsets[i],
                                              offset_first,
                                              offset_first + 1,
                                              0,
                                              sizeof(vertex_t) * 8,
                                              handle.get_stream());
    }
    thrust::copy(handle.get_thrust_policy(),
                 segment_sorted_indices.begin(),
                 segment_sorted_indices.begin() + (h_edge_offsets[i + 1] - h_edge_offsets[i]),
                 indices + h_edge_offsets[i]);
    if (weights) {
      thrust::copy(handle.get_thrust_policy(),
                   (*segment_sorted_weights).begin(),
                   (*segment_sorted_weights).begin() + (h_edge_offsets[i + 1] - h_edge_offsets[i]),
                   (*weights) + h_edge_offsets[i]);
    }
  }
}

}  // namespace

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  graph_t(raft::handle_t const& handle,
          std::vector<edgelist_t<vertex_t, edge_t, weight_t>> const& edgelists,
          graph_meta_t<vertex_t, edge_t, multi_gpu> meta,
          bool do_expensive_check)
  : detail::graph_base_t<vertex_t, edge_t, weight_t>(
      handle, meta.number_of_vertices, meta.number_of_edges, meta.properties),
    partition_(meta.partition)
{
  // cheap error checks

  auto& comm           = this->get_handle_ptr()->get_comms();
  auto const comm_size = comm.get_size();
  auto& row_comm =
    this->get_handle_ptr()->get_subcomm(cugraph::partition_2d::key_naming_t().row_name());
  auto const row_comm_rank = row_comm.get_rank();
  auto const row_comm_size = row_comm.get_size();
  auto& col_comm =
    this->get_handle_ptr()->get_subcomm(cugraph::partition_2d::key_naming_t().col_name());
  auto const col_comm_rank = col_comm.get_rank();
  auto const col_comm_size = col_comm.get_size();
  auto default_stream_view = this->get_handle_ptr()->get_stream_view();

  CUGRAPH_EXPECTS(edgelists.size() == static_cast<size_t>(col_comm_size),
                  "Invalid input argument: erroneous edgelists.size().");
  CUGRAPH_EXPECTS(
    !(meta.segment_offsets).has_value() ||
      ((*(meta.segment_offsets)).size() ==
       (detail::num_sparse_segments_per_vertex_partition + 1)) ||
      ((*(meta.segment_offsets)).size() == (detail::num_sparse_segments_per_vertex_partition + 2)),
    "Invalid input argument: (*(meta.segment_offsets)).size() returns an invalid value.");

  auto is_weighted = edgelists[0].p_edge_weights.has_value();
  auto use_dcs =
    meta.segment_offsets
      ? ((*(meta.segment_offsets)).size() > (detail::num_sparse_segments_per_vertex_partition + 1))
      : false;

  CUGRAPH_EXPECTS(
    std::any_of(edgelists.begin(),
                edgelists.end(),
                [is_weighted](auto edgelist) {
                  return ((edgelist.number_of_edges > 0) && (edgelist.p_src_vertices == nullptr)) ||
                         ((edgelist.number_of_edges > 0) && (edgelist.p_dst_vertices == nullptr)) ||
                         (is_weighted && (edgelist.number_of_edges > 0) &&
                          ((edgelist.p_edge_weights.has_value() == false) ||
                           (*(edgelist.p_edge_weights) == nullptr)));
                }) == false,
    "Invalid input argument: edgelists[].p_src_vertices and edgelists[].p_dst_vertices should not "
    "be nullptr if edgelists[].number_of_edges > 0 and edgelists[].p_edge_weights should be "
    "neither std::nullopt nor nullptr if weighted and edgelists[].number_of_edges >  0.");

  // optional expensive checks

  if (do_expensive_check) {
    edge_t number_of_local_edges{0};
    for (size_t i = 0; i < edgelists.size(); ++i) {
      auto [major_first, major_last] = partition_.get_matrix_partition_major_range(i);
      auto [minor_first, minor_last] = partition_.get_matrix_partition_minor_range();

      number_of_local_edges += edgelists[i].number_of_edges;

      auto edge_first = thrust::make_zip_iterator(thrust::make_tuple(
        store_transposed ? edgelists[i].p_dst_vertices : edgelists[i].p_src_vertices,
        store_transposed ? edgelists[i].p_src_vertices : edgelists[i].p_dst_vertices));
      // better use thrust::any_of once https://github.com/thrust/thrust/issues/1016 is resolved
      CUGRAPH_EXPECTS(thrust::count_if(rmm::exec_policy(default_stream_view),
                                       edge_first,
                                       edge_first + edgelists[i].number_of_edges,
                                       out_of_range_t<vertex_t>{
                                         major_first, major_last, minor_first, minor_last}) == 0,
                      "Invalid input argument: edgelists[] have out-of-range values.");
    }
    auto number_of_local_edges_sum = host_scalar_allreduce(
      comm, number_of_local_edges, raft::comms::op_t::SUM, default_stream_view.value());
    CUGRAPH_EXPECTS(number_of_local_edges_sum == this->get_number_of_edges(),
                    "Invalid input argument: the sum of local edge counts does not match with "
                    "meta.number_of_edges.");

    CUGRAPH_EXPECTS(
      partition_.get_vertex_partition_last(comm_size - 1) == meta.number_of_vertices,
      "Invalid input argument: vertex partition should cover [0, meta.number_of_vertices).");

    if (this->is_symmetric()) {
      CUGRAPH_EXPECTS(
        (check_symmetric<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>(handle,
                                                                                  edgelists)),
        "Invalid input argument: meta.property.is_symmetric is true but the input edge list is not "
        "symmetric.");
    }
    if (!this->is_multigraph()) {
      CUGRAPH_EXPECTS(
        check_no_parallel_edge(handle, edgelists),
        "Invalid input argument: meta.property.is_multigraph is false but the input edge list has "
        "parallel edges.");
    }

    rmm::device_uvector<vertex_t> majors(number_of_local_edges, handle.get_stream());
    rmm::device_uvector<vertex_t> minors(number_of_local_edges, handle.get_stream());
    size_t cur_size{0};
    for (size_t i = 0; i < edgelists.size(); ++i) {
      auto p_majors = store_transposed ? edgelists[i].p_dst_vertices : edgelists[i].p_src_vertices;
      auto p_minors = store_transposed ? edgelists[i].p_src_vertices : edgelists[i].p_dst_vertices;
      thrust::copy(handle.get_thrust_policy(),
                   p_majors,
                   p_majors + edgelists[i].number_of_edges,
                   majors.begin() + cur_size);
      thrust::copy(handle.get_thrust_policy(),
                   p_minors,
                   p_minors + edgelists[i].number_of_edges,
                   minors.begin() + cur_size);
      cur_size += edgelists[i].number_of_edges;
    }
    thrust::sort(handle.get_thrust_policy(), majors.begin(), majors.end());
    thrust::sort(handle.get_thrust_policy(), minors.begin(), minors.end());
    auto num_local_unique_edge_majors = static_cast<vertex_t>(thrust::distance(
      majors.begin(), thrust::unique(handle.get_thrust_policy(), majors.begin(), majors.end())));
    auto num_local_unique_edge_minors = static_cast<vertex_t>(thrust::distance(
      minors.begin(), thrust::unique(handle.get_thrust_policy(), minors.begin(), minors.end())));
    // FIXME: temporarily disable this check as these are currently not used
    // (row_col_properties_kv_pair_fill_ratio_threshold is set to 0.0, so (key, value) pairs for
    // row/column properties will be never enabled) and we're not currently exposing this to the
    // python layer. Should be re-enabled later once we enable the (key, value) pair feature and
    // hopefully simplify the python graph creation pipeline as well (so no need to pass this
    // information to the python layer).
#if 0
    if constexpr (store_transposed) {
      CUGRAPH_EXPECTS(num_local_unique_edge_majors == meta.num_local_unique_edge_cols,
                      "Invalid input argument: num_local_unique_edge_cols is erroneous.");
      CUGRAPH_EXPECTS(num_local_unique_edge_minors == meta.num_local_unique_edge_rows,
                      "Invalid input argument: num_local_unique_edge_rows is erroneous.");
    } else {
      CUGRAPH_EXPECTS(num_local_unique_edge_majors == meta.num_local_unique_edge_rows,
                      "Invalid input argument: num_local_unique_edge_rows is erroneous.");
      CUGRAPH_EXPECTS(num_local_unique_edge_minors == meta.num_local_unique_edge_cols,
                      "Invalid input argument: num_local_unique_edge_cols is erroneous.");
    }
#endif
  }

  // aggregate segment_offsets

  if (meta.segment_offsets) {
    // FIXME: we need to add host_allgather
    rmm::device_uvector<vertex_t> d_segment_offsets((*(meta.segment_offsets)).size(),
                                                    default_stream_view);
    raft::update_device(d_segment_offsets.data(),
                        (*(meta.segment_offsets)).data(),
                        (*(meta.segment_offsets)).size(),
                        default_stream_view.value());
    rmm::device_uvector<vertex_t> d_aggregate_segment_offsets(
      col_comm_size * d_segment_offsets.size(), default_stream_view);
    col_comm.allgather(d_segment_offsets.data(),
                       d_aggregate_segment_offsets.data(),
                       d_segment_offsets.size(),
                       default_stream_view.value());

    adj_matrix_partition_segment_offsets_ =
      std::vector<vertex_t>(d_aggregate_segment_offsets.size(), vertex_t{0});
    raft::update_host((*adj_matrix_partition_segment_offsets_).data(),
                      d_aggregate_segment_offsets.data(),
                      d_aggregate_segment_offsets.size(),
                      default_stream_view.value());

    default_stream_view
      .synchronize();  // this is necessary as adj_matrix_partition_segment_offsets_ can be used
                       // right after return.
  }

  // compress edge list (COO) to CSR (or CSC) or CSR + DCSR (CSC + DCSC) hybrid

  adj_matrix_partition_offsets_.reserve(edgelists.size());
  adj_matrix_partition_indices_.reserve(edgelists.size());
  if (is_weighted) {
    adj_matrix_partition_weights_ = std::vector<rmm::device_uvector<weight_t>>{};
    (*adj_matrix_partition_weights_).reserve(edgelists.size());
  }
  if (use_dcs) {
    adj_matrix_partition_dcs_nzd_vertices_      = std::vector<rmm::device_uvector<vertex_t>>{};
    adj_matrix_partition_dcs_nzd_vertex_counts_ = std::vector<vertex_t>{};
    (*adj_matrix_partition_dcs_nzd_vertices_).reserve(edgelists.size());
    (*adj_matrix_partition_dcs_nzd_vertex_counts_).reserve(edgelists.size());
  }
  for (size_t i = 0; i < edgelists.size(); ++i) {
    auto [major_first, major_last] = partition_.get_matrix_partition_major_range(i);
    auto [minor_first, minor_last] = partition_.get_matrix_partition_minor_range();
    auto major_hypersparse_first =
      use_dcs ? std::optional<vertex_t>{major_first +
                                        (*adj_matrix_partition_segment_offsets_)
                                          [(*(meta.segment_offsets)).size() * i +
                                           detail::num_sparse_segments_per_vertex_partition]}
              : std::nullopt;
    auto [offsets, indices, weights, dcs_nzd_vertices] =
      compress_edgelist<store_transposed>(edgelists[i],
                                          major_first,
                                          major_hypersparse_first,
                                          major_last,
                                          minor_first,
                                          minor_last,
                                          default_stream_view);

    adj_matrix_partition_offsets_.push_back(std::move(offsets));
    adj_matrix_partition_indices_.push_back(std::move(indices));
    if (is_weighted) { (*adj_matrix_partition_weights_).push_back(std::move(*weights)); }
    if (use_dcs) {
      auto dcs_nzd_vertex_count = static_cast<vertex_t>((*dcs_nzd_vertices).size());
      (*adj_matrix_partition_dcs_nzd_vertices_).push_back(std::move(*dcs_nzd_vertices));
      (*adj_matrix_partition_dcs_nzd_vertex_counts_).push_back(dcs_nzd_vertex_count);
    }
  }

  // segmented sort neighbors

  for (size_t i = 0; i < adj_matrix_partition_offsets_.size(); ++i) {
    sort_adjacency_list(handle,
                        adj_matrix_partition_offsets_[i].data(),
                        adj_matrix_partition_indices_[i].data(),
                        adj_matrix_partition_weights_
                          ? std::optional<weight_t*>{(*adj_matrix_partition_weights_)[i].data()}
                          : std::nullopt,
                        static_cast<vertex_t>(adj_matrix_partition_offsets_[i].size() - 1),
                        static_cast<edge_t>(adj_matrix_partition_indices_[i].size()));
  }

  // if # unique edge rows/cols << V / row_comm_size|col_comm_size, store unique edge rows/cols to
  // support storing edge row/column properties in (key, value) pairs.

  auto num_local_unique_edge_majors =
    store_transposed ? meta.num_local_unique_edge_cols : meta.num_local_unique_edge_rows;
  auto num_local_unique_edge_minors =
    store_transposed ? meta.num_local_unique_edge_rows : meta.num_local_unique_edge_cols;

  vertex_t aggregate_major_size{0};
  for (size_t i = 0; i < partition_.get_number_of_matrix_partitions(); ++i) {
    aggregate_major_size += partition_.get_matrix_partition_major_size(i);
  }
  auto minor_size                      = partition_.get_matrix_partition_minor_size();
  auto max_major_properties_fill_ratio = host_scalar_allreduce(
    comm,
    static_cast<double>(num_local_unique_edge_majors) / static_cast<double>(aggregate_major_size),
    raft::comms::op_t::MAX,
    handle.get_stream());
  auto max_minor_properties_fill_ratio = host_scalar_allreduce(
    comm,
    static_cast<double>(num_local_unique_edge_minors) / static_cast<double>(minor_size),
    raft::comms::op_t::MAX,
    handle.get_stream());

  if (max_major_properties_fill_ratio < detail::row_col_properties_kv_pair_fill_ratio_threshold) {
    rmm::device_uvector<vertex_t> local_sorted_unique_edge_majors(num_local_unique_edge_majors,
                                                                  handle.get_stream());
    size_t cur_size{0};
    for (size_t i = 0; i < adj_matrix_partition_offsets_.size(); ++i) {
      auto [major_first, major_last] = partition_.get_matrix_partition_major_range(i);
      auto major_hypersparse_first =
        use_dcs ? std::optional<vertex_t>{major_first +
                                          (*adj_matrix_partition_segment_offsets_)
                                            [(*(meta.segment_offsets)).size() * i +
                                             detail::num_sparse_segments_per_vertex_partition]}
                : std::nullopt;
      cur_size += thrust::distance(
        local_sorted_unique_edge_majors.data() + cur_size,
        thrust::copy_if(
          handle.get_thrust_policy(),
          thrust::make_counting_iterator(major_first),
          thrust::make_counting_iterator(use_dcs ? *major_hypersparse_first : major_last),
          local_sorted_unique_edge_majors.data() + cur_size,
          has_nzd_t<vertex_t, edge_t>{adj_matrix_partition_offsets_[i].data(), major_first}));
      if (use_dcs) {
        thrust::copy(handle.get_thrust_policy(),
                     (*adj_matrix_partition_dcs_nzd_vertices_)[i].begin(),
                     (*adj_matrix_partition_dcs_nzd_vertices_)[i].begin() +
                       (*adj_matrix_partition_dcs_nzd_vertex_counts_)[i],
                     local_sorted_unique_edge_majors.data() + cur_size);
        cur_size += (*adj_matrix_partition_dcs_nzd_vertex_counts_)[i];
      }
    }
    assert(cur_size == num_local_unique_edge_majors);

    std::vector<vertex_t> h_vertex_partition_firsts(col_comm_size - 1);
    for (int i = 1; i < col_comm_size; ++i) {
      h_vertex_partition_firsts[i - 1] =
        partition_.get_vertex_partition_first(i * row_comm_size + row_comm_rank);
    }
    rmm::device_uvector<vertex_t> d_vertex_partition_firsts(h_vertex_partition_firsts.size(),
                                                            handle.get_stream());
    raft::update_device(d_vertex_partition_firsts.data(),
                        h_vertex_partition_firsts.data(),
                        h_vertex_partition_firsts.size(),
                        handle.get_stream());
    rmm::device_uvector<vertex_t> d_key_offsets(d_vertex_partition_firsts.size(),
                                                handle.get_stream());
    thrust::lower_bound(handle.get_thrust_policy(),
                        local_sorted_unique_edge_majors.begin(),
                        local_sorted_unique_edge_majors.end(),
                        d_vertex_partition_firsts.begin(),
                        d_vertex_partition_firsts.end(),
                        d_key_offsets.begin());
    std::vector<vertex_t> h_key_offsets(col_comm_size + 1, vertex_t{0});
    h_key_offsets.back() = static_cast<vertex_t>(local_sorted_unique_edge_majors.size());
    raft::update_host(
      h_key_offsets.data() + 1, d_key_offsets.data(), d_key_offsets.size(), handle.get_stream());

    if constexpr (store_transposed) {
      local_sorted_unique_edge_cols_        = std::move(local_sorted_unique_edge_majors);
      local_sorted_unique_edge_col_offsets_ = std::move(h_key_offsets);
    } else {
      local_sorted_unique_edge_rows_        = std::move(local_sorted_unique_edge_majors);
      local_sorted_unique_edge_row_offsets_ = std::move(h_key_offsets);
    }
  }

  if (max_minor_properties_fill_ratio < detail::row_col_properties_kv_pair_fill_ratio_threshold) {
    rmm::device_uvector<vertex_t> local_sorted_unique_edge_minors(0, handle.get_stream());
    for (size_t i = 0; i < adj_matrix_partition_indices_.size(); ++i) {
      rmm::device_uvector<vertex_t> tmp_minors(adj_matrix_partition_indices_[i].size(),
                                               handle.get_stream());
      thrust::copy(handle.get_thrust_policy(),
                   adj_matrix_partition_indices_[i].begin(),
                   adj_matrix_partition_indices_[i].end(),
                   tmp_minors.begin());
      thrust::sort(handle.get_thrust_policy(), tmp_minors.begin(), tmp_minors.end());
      tmp_minors.resize(
        thrust::distance(
          tmp_minors.begin(),
          thrust::unique(handle.get_thrust_policy(), tmp_minors.begin(), tmp_minors.end())),
        handle.get_stream());
      auto cur_size = local_sorted_unique_edge_minors.size();
      if (cur_size == 0) {
        local_sorted_unique_edge_minors = std::move(tmp_minors);
      } else {
        local_sorted_unique_edge_minors.resize(
          local_sorted_unique_edge_minors.size() + tmp_minors.size(), handle.get_stream());
        thrust::copy(handle.get_thrust_policy(),
                     tmp_minors.begin(),
                     tmp_minors.end(),
                     local_sorted_unique_edge_minors.begin() + cur_size);
      }
    }
    thrust::sort(handle.get_thrust_policy(),
                 local_sorted_unique_edge_minors.begin(),
                 local_sorted_unique_edge_minors.end());
    local_sorted_unique_edge_minors.resize(
      thrust::distance(local_sorted_unique_edge_minors.begin(),
                       thrust::unique(handle.get_thrust_policy(),
                                      local_sorted_unique_edge_minors.begin(),
                                      local_sorted_unique_edge_minors.end())),
      handle.get_stream());
    local_sorted_unique_edge_minors.shrink_to_fit(handle.get_stream());

    std::vector<vertex_t> h_vertex_partition_firsts(row_comm_size - 1);
    for (int i = 1; i < row_comm_size; ++i) {
      h_vertex_partition_firsts[i - 1] =
        partition_.get_vertex_partition_first(col_comm_rank * row_comm_size + i);
    }
    rmm::device_uvector<vertex_t> d_vertex_partition_firsts(h_vertex_partition_firsts.size(),
                                                            handle.get_stream());
    raft::update_device(d_vertex_partition_firsts.data(),
                        h_vertex_partition_firsts.data(),
                        h_vertex_partition_firsts.size(),
                        handle.get_stream());
    rmm::device_uvector<vertex_t> d_key_offsets(d_vertex_partition_firsts.size(),
                                                handle.get_stream());
    thrust::lower_bound(handle.get_thrust_policy(),
                        local_sorted_unique_edge_minors.begin(),
                        local_sorted_unique_edge_minors.end(),
                        d_vertex_partition_firsts.begin(),
                        d_vertex_partition_firsts.end(),
                        d_key_offsets.begin());
    std::vector<vertex_t> h_key_offsets(row_comm_size + 1, vertex_t{0});
    h_key_offsets.back() = static_cast<vertex_t>(local_sorted_unique_edge_minors.size());
    raft::update_host(
      h_key_offsets.data() + 1, d_key_offsets.data(), d_key_offsets.size(), handle.get_stream());

    if constexpr (store_transposed) {
      local_sorted_unique_edge_rows_        = std::move(local_sorted_unique_edge_minors);
      local_sorted_unique_edge_row_offsets_ = std::move(h_key_offsets);
    } else {
      local_sorted_unique_edge_cols_        = std::move(local_sorted_unique_edge_minors);
      local_sorted_unique_edge_col_offsets_ = std::move(h_key_offsets);
    }
  }
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<!multi_gpu>>::
  graph_t(raft::handle_t const& handle,
          edgelist_t<vertex_t, edge_t, weight_t> const& edgelist,
          graph_meta_t<vertex_t, edge_t, multi_gpu> meta,
          bool do_expensive_check)
  : detail::graph_base_t<vertex_t, edge_t, weight_t>(
      handle, meta.number_of_vertices, edgelist.number_of_edges, meta.properties),
    offsets_(rmm::device_uvector<edge_t>(0, handle.get_stream_view())),
    indices_(rmm::device_uvector<vertex_t>(0, handle.get_stream_view())),
    segment_offsets_(meta.segment_offsets)
{
  // cheap error checks

  auto default_stream_view = this->get_handle_ptr()->get_stream_view();

  auto is_weighted = edgelist.p_edge_weights.has_value();

  CUGRAPH_EXPECTS(
    ((edgelist.number_of_edges == 0) || (edgelist.p_src_vertices != nullptr)) &&
      ((edgelist.number_of_edges == 0) || (edgelist.p_dst_vertices != nullptr)) &&
      (!is_weighted || (is_weighted && ((edgelist.number_of_edges == 0) ||
                                        (*(edgelist.p_edge_weights) != nullptr)))),
    "Invalid input argument: edgelist.p_src_vertices and edgelist.p_dst_vertices should not be "
    "nullptr if edgelist.number_of_edges > 0 and edgelist.p_edge_weights should be neither "
    "std::nullopt nor nullptr if weighted and edgelist.number_of_edges > 0.");

  CUGRAPH_EXPECTS(
    !segment_offsets_.has_value() ||
      ((*segment_offsets_).size() == (detail::num_sparse_segments_per_vertex_partition + 1)),
    "Invalid input argument: (*(meta.segment_offsets)).size() returns an invalid value.");

  // optional expensive checks

  if (do_expensive_check) {
    auto edge_first = thrust::make_zip_iterator(
      thrust::make_tuple(store_transposed ? edgelist.p_dst_vertices : edgelist.p_src_vertices,
                         store_transposed ? edgelist.p_src_vertices : edgelist.p_dst_vertices));
    // better use thrust::any_of once https://github.com/thrust/thrust/issues/1016 is resolved
    CUGRAPH_EXPECTS(thrust::count_if(
                      rmm::exec_policy(default_stream_view),
                      edge_first,
                      edge_first + edgelist.number_of_edges,
                      out_of_range_t<vertex_t>{
                        0, this->get_number_of_vertices(), 0, this->get_number_of_vertices()}) == 0,
                    "Invalid input argument: edgelist have out-of-range values.");

    if (this->is_symmetric()) {
      CUGRAPH_EXPECTS(
        (check_symmetric<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>(
          handle, std::vector<edgelist_t<vertex_t, edge_t, weight_t>>{edgelist})),
        "Invalid input argument: meta.property.is_symmetric is true but the input edge list is not "
        "symmetric.");
    }
    if (!this->is_multigraph()) {
      CUGRAPH_EXPECTS(
        check_no_parallel_edge(handle,
                               std::vector<edgelist_t<vertex_t, edge_t, weight_t>>{edgelist}),
        "Invalid input argument: meta.property.is_multigraph is false but the input edge list has "
        "parallel edges.");
    }
  }

  // convert edge list (COO) to compressed sparse format (CSR or CSC)

  std::tie(offsets_, indices_, weights_, std::ignore) =
    compress_edgelist<store_transposed>(edgelist,
                                        vertex_t{0},
                                        std::optional<vertex_t>{std::nullopt},
                                        this->get_number_of_vertices(),
                                        vertex_t{0},
                                        this->get_number_of_vertices(),
                                        default_stream_view);

  // segmented sort neighbors

  sort_adjacency_list(handle,
                      offsets_.data(),
                      indices_.data(),
                      weights_ ? std::optional<weight_t*>{(*weights_).data()} : std::nullopt,
                      static_cast<vertex_t>(offsets_.size() - 1),
                      static_cast<edge_t>(indices_.size()));
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<vertex_t>
graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  symmetrize(raft::handle_t const& handle,
             rmm::device_uvector<vertex_t>&& renumber_map,
             bool reciprocal)
{
  if (this->is_symmetric()) { return std::move(renumber_map); }

  auto is_multigraph = this->is_multigraph();

  auto wrapped_renumber_map = std::optional<rmm::device_uvector<vertex_t>>(std::move(renumber_map));

  auto [edgelist_rows, edgelist_cols, edgelist_weights] =
    this->decompress_to_edgelist(handle, wrapped_renumber_map, true);

  std::tie(edgelist_rows, edgelist_cols, edgelist_weights) =
    symmetrize_edgelist<vertex_t, weight_t, store_transposed, multi_gpu>(
      handle,
      std::move(edgelist_rows),
      std::move(edgelist_cols),
      std::move(edgelist_weights),
      reciprocal);

  auto [symmetrized_graph, new_renumber_map] =
    create_graph_from_edgelist<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>(
      handle,
      std::move(*wrapped_renumber_map),
      std::move(edgelist_rows),
      std::move(edgelist_cols),
      std::move(edgelist_weights),
      graph_properties_t{is_multigraph, true},
      true);
  *this = std::move(symmetrized_graph);

  return std::move(*new_renumber_map);
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
std::optional<rmm::device_uvector<vertex_t>>
graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<!multi_gpu>>::
  symmetrize(raft::handle_t const& handle,
             std::optional<rmm::device_uvector<vertex_t>>&& renumber_map,
             bool reciprocal)
{
  if (this->is_symmetric()) { return std::move(renumber_map); }

  auto number_of_vertices = this->get_number_of_vertices();
  auto is_multigraph      = this->is_multigraph();
  bool renumber           = renumber_map.has_value();

  auto [edgelist_rows, edgelist_cols, edgelist_weights] =
    this->decompress_to_edgelist(handle, renumber_map, true);

  std::tie(edgelist_rows, edgelist_cols, edgelist_weights) =
    symmetrize_edgelist<vertex_t, weight_t, store_transposed, multi_gpu>(
      handle,
      std::move(edgelist_rows),
      std::move(edgelist_cols),
      std::move(edgelist_weights),
      reciprocal);

  auto vertex_span = renumber ? std::move(renumber_map)
                              : std::make_optional<rmm::device_uvector<vertex_t>>(
                                  number_of_vertices, handle.get_stream());
  if (!renumber) {
    thrust::sequence(
      handle.get_thrust_policy(), (*vertex_span).begin(), (*vertex_span).end(), vertex_t{0});
  }

  auto [symmetrized_graph, new_renumber_map] =
    create_graph_from_edgelist<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>(
      handle,
      std::move(vertex_span),
      std::move(edgelist_rows),
      std::move(edgelist_cols),
      std::move(edgelist_weights),
      graph_properties_t{is_multigraph, true},
      renumber);
  *this = std::move(symmetrized_graph);

  return std::move(new_renumber_map);
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
rmm::device_uvector<vertex_t>
graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  transpose(raft::handle_t const& handle, rmm::device_uvector<vertex_t>&& renumber_map)
{
  if (this->is_symmetric()) { return std::move(renumber_map); }

  auto is_multigraph = this->is_multigraph();

  auto wrapped_renumber_map = std::optional<rmm::device_uvector<vertex_t>>(std::move(renumber_map));

  auto [edgelist_rows, edgelist_cols, edgelist_weights] =
    this->decompress_to_edgelist(handle, wrapped_renumber_map, true);

  std::tie(store_transposed ? edgelist_rows : edgelist_cols,
           store_transposed ? edgelist_cols : edgelist_rows,
           edgelist_weights) =
    detail::shuffle_edgelist_by_gpu_id(handle,
                                       std::move(store_transposed ? edgelist_rows : edgelist_cols),
                                       std::move(store_transposed ? edgelist_cols : edgelist_rows),
                                       std::move(edgelist_weights));

  auto [transposed_graph, new_renumber_map] =
    create_graph_from_edgelist<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>(
      handle,
      std::move(*wrapped_renumber_map),
      std::move(edgelist_cols),
      std::move(edgelist_rows),
      std::move(edgelist_weights),
      graph_properties_t{is_multigraph, false},
      true);
  *this = std::move(transposed_graph);

  return std::move(*new_renumber_map);
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
std::optional<rmm::device_uvector<vertex_t>>
graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<!multi_gpu>>::
  transpose(raft::handle_t const& handle,
            std::optional<rmm::device_uvector<vertex_t>>&& renumber_map)
{
  if (this->is_symmetric()) { return std::move(renumber_map); }

  auto number_of_vertices = this->get_number_of_vertices();
  auto is_multigraph      = this->is_multigraph();
  bool renumber           = renumber_map.has_value();

  auto [edgelist_rows, edgelist_cols, edgelist_weights] =
    this->decompress_to_edgelist(handle, renumber_map, true);
  auto vertex_span = renumber ? std::move(renumber_map)
                              : std::make_optional<rmm::device_uvector<vertex_t>>(
                                  number_of_vertices, handle.get_stream());
  if (!renumber) {
    thrust::sequence(
      handle.get_thrust_policy(), (*vertex_span).begin(), (*vertex_span).end(), vertex_t{0});
  }

  auto [transposed_graph, new_renumber_map] =
    create_graph_from_edgelist<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>(
      handle,
      std::move(vertex_span),
      std::move(edgelist_cols),
      std::move(edgelist_rows),
      std::move(edgelist_weights),
      graph_properties_t{is_multigraph, false},
      renumber);
  *this = std::move(transposed_graph);

  return std::move(new_renumber_map);
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
std::tuple<graph_t<vertex_t, edge_t, weight_t, !store_transposed, multi_gpu>,
           rmm::device_uvector<vertex_t>>
graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  transpose_storage(raft::handle_t const& handle,
                    rmm::device_uvector<vertex_t>&& renumber_map,
                    bool destroy)
{
  auto is_multigraph = this->is_multigraph();

  auto wrapped_renumber_map = std::optional<rmm::device_uvector<vertex_t>>(std::move(renumber_map));

  auto [edgelist_rows, edgelist_cols, edgelist_weights] =
    this->decompress_to_edgelist(handle, wrapped_renumber_map, destroy);

  std::tie(!store_transposed ? edgelist_cols : edgelist_rows,
           !store_transposed ? edgelist_rows : edgelist_cols,
           edgelist_weights) =
    detail::shuffle_edgelist_by_gpu_id(handle,
                                       std::move(!store_transposed ? edgelist_cols : edgelist_rows),
                                       std::move(!store_transposed ? edgelist_rows : edgelist_cols),
                                       std::move(edgelist_weights));

  auto [storage_transposed_graph, new_renumber_map] =
    create_graph_from_edgelist<vertex_t, edge_t, weight_t, !store_transposed, multi_gpu>(
      handle,
      std::move(*wrapped_renumber_map),
      std::move(edgelist_rows),
      std::move(edgelist_cols),
      std::move(edgelist_weights),
      graph_properties_t{is_multigraph, false},
      true);

  return std::make_tuple(std::move(storage_transposed_graph), std::move(*new_renumber_map));
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
std::tuple<graph_t<vertex_t, edge_t, weight_t, !store_transposed, multi_gpu>,
           std::optional<rmm::device_uvector<vertex_t>>>
graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<!multi_gpu>>::
  transpose_storage(raft::handle_t const& handle,
                    std::optional<rmm::device_uvector<vertex_t>>&& renumber_map,
                    bool destroy)
{
  auto number_of_vertices = this->get_number_of_vertices();
  auto is_multigraph      = this->is_multigraph();
  bool renumber           = renumber_map.has_value();

  auto [edgelist_rows, edgelist_cols, edgelist_weights] =
    this->decompress_to_edgelist(handle, renumber_map, destroy);
  auto vertex_span = renumber ? std::move(renumber_map)
                              : std::make_optional<rmm::device_uvector<vertex_t>>(
                                  number_of_vertices, handle.get_stream());
  if (!renumber) {
    thrust::sequence(
      handle.get_thrust_policy(), (*vertex_span).begin(), (*vertex_span).end(), vertex_t{0});
  }

  return create_graph_from_edgelist<vertex_t, edge_t, weight_t, !store_transposed, multi_gpu>(
    handle,
    std::move(vertex_span),
    std::move(edgelist_cols),
    std::move(edgelist_rows),
    std::move(edgelist_weights),
    graph_properties_t{is_multigraph, false},
    renumber);
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>,
           rmm::device_uvector<vertex_t>,
           std::optional<rmm::device_uvector<weight_t>>>
graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<multi_gpu>>::
  decompress_to_edgelist(raft::handle_t const& handle,
                         std::optional<rmm::device_uvector<vertex_t>> const& renumber_map,
                         bool destroy)
{
  auto& comm           = handle.get_comms();
  auto const comm_size = comm.get_size();
  auto& row_comm =
    this->get_handle_ptr()->get_subcomm(cugraph::partition_2d::key_naming_t().row_name());
  auto const row_comm_size = row_comm.get_size();
  auto& col_comm =
    this->get_handle_ptr()->get_subcomm(cugraph::partition_2d::key_naming_t().col_name());
  auto const col_comm_rank = col_comm.get_rank();

  auto graph_view = this->view();

  std::vector<size_t> edgelist_edge_counts(graph_view.get_number_of_local_adj_matrix_partitions(),
                                           size_t{0});
  for (size_t i = 0; i < edgelist_edge_counts.size(); ++i) {
    edgelist_edge_counts[i] =
      static_cast<size_t>(graph_view.get_number_of_local_adj_matrix_partition_edges(i));
  }
  auto number_of_local_edges =
    std::reduce(edgelist_edge_counts.begin(), edgelist_edge_counts.end());
  auto vertex_partition_lasts = graph_view.get_vertex_partition_lasts();

  rmm::device_uvector<vertex_t> edgelist_majors(number_of_local_edges, handle.get_stream());
  rmm::device_uvector<vertex_t> edgelist_minors(edgelist_majors.size(), handle.get_stream());
  auto edgelist_weights = this->is_weighted() ? std::make_optional<rmm::device_uvector<weight_t>>(
                                                  edgelist_majors.size(), handle.get_stream())
                                              : std::nullopt;

  size_t cur_size{0};
  for (size_t i = 0; i < edgelist_edge_counts.size(); ++i) {
    detail::decompress_matrix_partition_to_edgelist(
      handle,
      matrix_partition_device_view_t<vertex_t, edge_t, weight_t, multi_gpu>(
        graph_view.get_matrix_partition_view(i)),
      edgelist_majors.data() + cur_size,
      edgelist_minors.data() + cur_size,
      edgelist_weights ? std::optional<weight_t*>{(*edgelist_weights).data() + cur_size}
                       : std::nullopt,
      graph_view.get_local_adj_matrix_partition_segment_offsets(i));
    cur_size += edgelist_edge_counts[i];
  }

  auto local_vertex_first = graph_view.get_local_vertex_first();
  auto local_vertex_last  = graph_view.get_local_vertex_last();

  if (destroy) { *this = graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>(handle); }

  if (renumber_map) {
    std::vector<vertex_t> h_thresholds(row_comm_size - 1, vertex_t{0});
    for (int i = 0; i < row_comm_size - 1; ++i) {
      h_thresholds[i] = graph_view.get_vertex_partition_last(col_comm_rank * row_comm_size + i);
    }
    rmm::device_uvector<vertex_t> d_thresholds(h_thresholds.size(), handle.get_stream());
    raft::update_device(
      d_thresholds.data(), h_thresholds.data(), h_thresholds.size(), handle.get_stream());

    std::vector<vertex_t*> major_ptrs(edgelist_edge_counts.size());
    std::vector<vertex_t*> minor_ptrs(major_ptrs.size());
    auto edgelist_intra_partition_segment_offsets =
      std::make_optional<std::vector<std::vector<size_t>>>(
        major_ptrs.size(), std::vector<size_t>(row_comm_size + 1, size_t{0}));
    size_t cur_size{0};
    for (size_t i = 0; i < graph_view.get_number_of_local_adj_matrix_partitions(); ++i) {
      major_ptrs[i] = edgelist_majors.data() + cur_size;
      minor_ptrs[i] = edgelist_minors.data() + cur_size;
      if (edgelist_weights) {
        thrust::sort_by_key(handle.get_thrust_policy(),
                            minor_ptrs[i],
                            minor_ptrs[i] + edgelist_edge_counts[i],
                            thrust::make_zip_iterator(thrust::make_tuple(
                              major_ptrs[i], (*edgelist_weights).data() + cur_size)));
      } else {
        thrust::sort_by_key(handle.get_thrust_policy(),
                            minor_ptrs[i],
                            minor_ptrs[i] + edgelist_edge_counts[i],
                            major_ptrs[i]);
      }
      rmm::device_uvector<size_t> d_segment_offsets(d_thresholds.size(), handle.get_stream());
      thrust::lower_bound(handle.get_thrust_policy(),
                          minor_ptrs[i],
                          minor_ptrs[i] + edgelist_edge_counts[i],
                          d_thresholds.begin(),
                          d_thresholds.end(),
                          d_segment_offsets.begin(),
                          thrust::less<vertex_t>{});
      (*edgelist_intra_partition_segment_offsets)[i][0]     = size_t{0};
      (*edgelist_intra_partition_segment_offsets)[i].back() = edgelist_edge_counts[i];
      raft::update_host((*edgelist_intra_partition_segment_offsets)[i].data() + 1,
                        d_segment_offsets.data(),
                        d_segment_offsets.size(),
                        handle.get_stream());
      handle.get_stream_view().synchronize();
      cur_size += edgelist_edge_counts[i];
    }

    unrenumber_local_int_edges<vertex_t, store_transposed, multi_gpu>(
      handle,
      store_transposed ? minor_ptrs : major_ptrs,
      store_transposed ? major_ptrs : minor_ptrs,
      edgelist_edge_counts,
      (*renumber_map).data(),
      vertex_partition_lasts,
      edgelist_intra_partition_segment_offsets);
  }

  return std::make_tuple(store_transposed ? std::move(edgelist_minors) : std::move(edgelist_majors),
                         store_transposed ? std::move(edgelist_majors) : std::move(edgelist_minors),
                         std::move(edgelist_weights));
}

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>,
           rmm::device_uvector<vertex_t>,
           std::optional<rmm::device_uvector<weight_t>>>
graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu, std::enable_if_t<!multi_gpu>>::
  decompress_to_edgelist(raft::handle_t const& handle,
                         std::optional<rmm::device_uvector<vertex_t>> const& renumber_map,
                         bool destroy)
{
  auto graph_view = this->view();

  rmm::device_uvector<vertex_t> edgelist_majors(
    graph_view.get_number_of_local_adj_matrix_partition_edges(), handle.get_stream());
  rmm::device_uvector<vertex_t> edgelist_minors(edgelist_majors.size(), handle.get_stream());
  auto edgelist_weights = this->is_weighted() ? std::make_optional<rmm::device_uvector<weight_t>>(
                                                  edgelist_majors.size(), handle.get_stream())
                                              : std::nullopt;
  detail::decompress_matrix_partition_to_edgelist(
    handle,
    matrix_partition_device_view_t<vertex_t, edge_t, weight_t, multi_gpu>(
      graph_view.get_matrix_partition_view()),
    edgelist_majors.data(),
    edgelist_minors.data(),
    edgelist_weights ? std::optional<weight_t*>{(*edgelist_weights).data()} : std::nullopt,
    graph_view.get_local_adj_matrix_partition_segment_offsets());

  if (destroy) { *this = graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>(handle); }

  if (renumber_map) {
    unrenumber_local_int_edges<vertex_t, store_transposed, multi_gpu>(
      handle,
      store_transposed ? edgelist_minors.data() : edgelist_majors.data(),
      store_transposed ? edgelist_majors.data() : edgelist_minors.data(),
      edgelist_majors.size(),
      (*renumber_map).data(),
      (*renumber_map).size());
  }

  return std::make_tuple(store_transposed ? std::move(edgelist_minors) : std::move(edgelist_majors),
                         store_transposed ? std::move(edgelist_majors) : std::move(edgelist_minors),
                         std::move(edgelist_weights));
}

}  // namespace cugraph
