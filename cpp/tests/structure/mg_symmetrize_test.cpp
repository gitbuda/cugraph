/*
 * Copyright (c) 2021, NVIDIA CORPORATION.
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

#include <utilities/high_res_clock.h>
#include <utilities/base_fixture.hpp>
#include <utilities/device_comm_wrapper.hpp>
#include <utilities/test_graphs.hpp>
#include <utilities/test_utilities.hpp>
#include <utilities/thrust_wrapper.hpp>

#include <cugraph/algorithms.hpp>
#include <cugraph/partition_manager.hpp>

#include <raft/comms/comms.hpp>
#include <raft/comms/mpi_comms.hpp>
#include <raft/handle.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/device_uvector.hpp>

#include <gtest/gtest.h>

#include <random>

struct Symmetrize_Usecase {
  bool reciprocal{false};
  bool test_weighted{false};
  bool check_correctness{true};
};

template <typename input_usecase_t>
class Tests_MGSymmetrize
  : public ::testing::TestWithParam<std::tuple<Symmetrize_Usecase, input_usecase_t>> {
 public:
  Tests_MGSymmetrize() {}
  static void SetupTestCase() {}
  static void TearDownTestCase() {}

  virtual void SetUp() {}
  virtual void TearDown() {}

  template <typename vertex_t, typename edge_t, typename weight_t, bool store_transposed>
  void run_current_test(Symmetrize_Usecase const& symmetrize_usecase,
                        input_usecase_t const& input_usecase)
  {
    // 1. initialize handle

    raft::handle_t handle{};
    HighResClock hr_clock{};

    raft::comms::initialize_mpi_comms(&handle, MPI_COMM_WORLD);
    auto& comm           = handle.get_comms();
    auto const comm_size = comm.get_size();
    auto const comm_rank = comm.get_rank();

    auto row_comm_size = static_cast<int>(sqrt(static_cast<double>(comm_size)));
    while (comm_size % row_comm_size != 0) {
      --row_comm_size;
    }
    cugraph::partition_2d::subcomm_factory_t<cugraph::partition_2d::key_naming_t, vertex_t>
      subcomm_factory(handle, row_comm_size);

    // 2. create MG graph

    if (cugraph::test::g_perf) {
      CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle.get_comms().barrier();
      hr_clock.start();
    }

    auto [mg_graph, d_mg_renumber_map_labels] =
      cugraph::test::construct_graph<vertex_t, edge_t, weight_t, store_transposed, true>(
        handle, input_usecase, symmetrize_usecase.test_weighted, true);

    if (cugraph::test::g_perf) {
      CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle.get_comms().barrier();
      double elapsed_time{0.0};
      hr_clock.stop(&elapsed_time);
      std::cout << "MG construct_graph took " << elapsed_time * 1e-6 << " s.\n";
    }

    // 3. run MG symmetrize

    if (cugraph::test::g_perf) {
      CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle.get_comms().barrier();
      hr_clock.start();
    }

    *d_mg_renumber_map_labels = mg_graph.symmetrize(
      handle, std::move(*d_mg_renumber_map_labels), symmetrize_usecase.reciprocal);

    if (cugraph::test::g_perf) {
      CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle.get_comms().barrier();
      double elapsed_time{0.0};
      hr_clock.stop(&elapsed_time);
      std::cout << "MG symmetrize took " << elapsed_time * 1e-6 << " s.\n";
    }

    // 4. copmare SG & MG results

    if (symmetrize_usecase.check_correctness) {
      // 4-1. decompress MG results

      auto [d_mg_rows, d_mg_cols, d_mg_weights] =
        mg_graph.decompress_to_edgelist(handle, d_mg_renumber_map_labels, false);

      // 4-2. aggregate MG results

      auto d_mg_aggregate_rows =
        cugraph::test::device_gatherv(handle, d_mg_rows.data(), d_mg_rows.size());
      auto d_mg_aggregate_cols =
        cugraph::test::device_gatherv(handle, d_mg_cols.data(), d_mg_cols.size());
      std::optional<rmm::device_uvector<weight_t>> d_mg_aggregate_weights{std::nullopt};
      if (d_mg_weights) {
        d_mg_aggregate_weights =
          cugraph::test::device_gatherv(handle, (*d_mg_weights).data(), (*d_mg_weights).size());
      }

      if (handle.get_comms().get_rank() == int{0}) {
        // 4-3. create SG graph

        cugraph::graph_t<vertex_t, edge_t, weight_t, store_transposed, false> sg_graph(handle);
        std::tie(sg_graph, std::ignore) =
          cugraph::test::construct_graph<vertex_t, edge_t, weight_t, store_transposed, false>(
            handle, input_usecase, symmetrize_usecase.test_weighted, false);

        // 4-4. run SG symmetrize

        auto d_sg_renumber_map_labels =
          sg_graph.symmetrize(handle, std::nullopt, symmetrize_usecase.reciprocal);
        ASSERT_FALSE(d_sg_renumber_map_labels.has_value());

        // 4-5. decompress SG results

        auto [d_sg_rows, d_sg_cols, d_sg_weights] =
          sg_graph.decompress_to_edgelist(handle, std::nullopt, false);

        // 4-6. compare

        ASSERT_TRUE(mg_graph.get_number_of_vertices() == sg_graph.get_number_of_vertices());
        ASSERT_TRUE(mg_graph.get_number_of_edges() == sg_graph.get_number_of_edges());

        std::vector<vertex_t> h_mg_aggregate_rows(d_mg_aggregate_rows.size());
        std::vector<vertex_t> h_mg_aggregate_cols(d_mg_aggregate_rows.size());
        auto h_mg_aggregate_weights =
          d_mg_aggregate_weights
            ? std::make_optional<std::vector<weight_t>>(d_mg_aggregate_rows.size())
            : std::nullopt;
        raft::update_host(h_mg_aggregate_rows.data(),
                          d_mg_aggregate_rows.data(),
                          d_mg_aggregate_rows.size(),
                          handle.get_stream());
        raft::update_host(h_mg_aggregate_cols.data(),
                          d_mg_aggregate_cols.data(),
                          d_mg_aggregate_cols.size(),
                          handle.get_stream());
        if (h_mg_aggregate_weights) {
          raft::update_host((*h_mg_aggregate_weights).data(),
                            (*d_mg_aggregate_weights).data(),
                            (*d_mg_aggregate_weights).size(),
                            handle.get_stream());
        }

        std::vector<vertex_t> h_sg_rows(d_sg_rows.size());
        std::vector<vertex_t> h_sg_cols(d_sg_rows.size());
        auto h_sg_weights =
          d_sg_weights ? std::make_optional<std::vector<weight_t>>(d_sg_rows.size()) : std::nullopt;
        raft::update_host(
          h_sg_rows.data(), d_sg_rows.data(), d_sg_rows.size(), handle.get_stream());
        raft::update_host(
          h_sg_cols.data(), d_sg_cols.data(), d_sg_cols.size(), handle.get_stream());
        if (h_sg_weights) {
          raft::update_host((*h_sg_weights).data(),
                            (*d_sg_weights).data(),
                            (*d_sg_weights).size(),
                            handle.get_stream());
        }

        if (symmetrize_usecase.test_weighted) {
          std::vector<std::tuple<vertex_t, vertex_t, weight_t>> mg_aggregate_edges(
            h_mg_aggregate_rows.size());
          for (size_t i = 0; i < mg_aggregate_edges.size(); ++i) {
            mg_aggregate_edges[i] = std::make_tuple(
              h_mg_aggregate_rows[i], h_mg_aggregate_cols[i], (*h_mg_aggregate_weights)[i]);
          }
          std::vector<std::tuple<vertex_t, vertex_t, weight_t>> sg_edges(h_sg_rows.size());
          for (size_t i = 0; i < sg_edges.size(); ++i) {
            sg_edges[i] = std::make_tuple(h_sg_rows[i], h_sg_cols[i], (*h_sg_weights)[i]);
          }
          std::sort(mg_aggregate_edges.begin(), mg_aggregate_edges.end());
          std::sort(sg_edges.begin(), sg_edges.end());
          ASSERT_TRUE(
            std::equal(mg_aggregate_edges.begin(), mg_aggregate_edges.end(), sg_edges.begin()));
        } else {
          std::vector<std::tuple<vertex_t, vertex_t>> mg_aggregate_edges(
            h_mg_aggregate_rows.size());
          for (size_t i = 0; i < mg_aggregate_edges.size(); ++i) {
            mg_aggregate_edges[i] = std::make_tuple(h_mg_aggregate_rows[i], h_mg_aggregate_cols[i]);
          }
          std::vector<std::tuple<vertex_t, vertex_t>> sg_edges(h_sg_rows.size());
          for (size_t i = 0; i < sg_edges.size(); ++i) {
            sg_edges[i] = std::make_tuple(h_sg_rows[i], h_sg_cols[i]);
          }
          std::sort(mg_aggregate_edges.begin(), mg_aggregate_edges.end());
          std::sort(sg_edges.begin(), sg_edges.end());
          ASSERT_TRUE(
            std::equal(mg_aggregate_edges.begin(), mg_aggregate_edges.end(), sg_edges.begin()));
        }
      }
    }
  }
};

using Tests_MGSymmetrize_File = Tests_MGSymmetrize<cugraph::test::File_Usecase>;
using Tests_MGSymmetrize_Rmat = Tests_MGSymmetrize<cugraph::test::Rmat_Usecase>;

TEST_P(Tests_MGSymmetrize_File, CheckInt32Int32FloatTransposedFalse)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, false>(std::get<0>(param), std::get<1>(param));
}

TEST_P(Tests_MGSymmetrize_File, CheckInt32Int32FloatTransposedTrue)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, true>(std::get<0>(param), std::get<1>(param));
}

TEST_P(Tests_MGSymmetrize_Rmat, CheckInt32Int32FloatTransposedFalse)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, false>(
    std::get<0>(param), override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGSymmetrize_Rmat, CheckInt32Int32FloatTransposedTrue)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, true>(
    std::get<0>(param), override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGSymmetrize_Rmat, CheckInt32Int64FloatTransposedFalse)
{
  auto param = GetParam();
  run_current_test<int32_t, int64_t, float, false>(
    std::get<0>(param), override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGSymmetrize_Rmat, CheckInt32Int64FloatTransposedTrue)
{
  auto param = GetParam();
  run_current_test<int32_t, int64_t, float, true>(
    std::get<0>(param), override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGSymmetrize_Rmat, CheckInt64Int64FloatTransposedFalse)
{
  auto param = GetParam();
  run_current_test<int64_t, int64_t, float, false>(
    std::get<0>(param), override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGSymmetrize_Rmat, CheckInt64Int64FloatTransposedTrue)
{
  auto param = GetParam();
  run_current_test<int64_t, int64_t, float, true>(
    std::get<0>(param), override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

INSTANTIATE_TEST_SUITE_P(
  file_test,
  Tests_MGSymmetrize_File,
  ::testing::Combine(
    // enable correctness checks
    ::testing::Values(Symmetrize_Usecase{false, false},
                      Symmetrize_Usecase{true, false},
                      Symmetrize_Usecase{false, true},
                      Symmetrize_Usecase{true, true}),
    ::testing::Values(cugraph::test::File_Usecase("test/datasets/karate.mtx"),
                      cugraph::test::File_Usecase("test/datasets/web-Google.mtx"),
                      cugraph::test::File_Usecase("test/datasets/webbase-1M.mtx"))));

INSTANTIATE_TEST_SUITE_P(rmat_small_test,
                         Tests_MGSymmetrize_Rmat,
                         ::testing::Combine(
                           // enable correctness checks
                           ::testing::Values(Symmetrize_Usecase{false, false},
                                             Symmetrize_Usecase{true, false},
                                             Symmetrize_Usecase{false, true},
                                             Symmetrize_Usecase{true, true}),
                           ::testing::Values(cugraph::test::Rmat_Usecase(
                             10, 16, 0.57, 0.19, 0.19, 0, false, false, 0, true))));

INSTANTIATE_TEST_SUITE_P(
  rmat_benchmark_test, /* note that scale & edge factor can be overridden in benchmarking (with
                          --gtest_filter to select only the rmat_benchmark_test with a specific
                          vertex & edge type combination) by command line arguments and do not
                          include more than one Rmat_Usecase that differ only in scale or edge
                          factor (to avoid running same benchmarks more than once) */
  Tests_MGSymmetrize_Rmat,
  ::testing::Combine(
    // disable correctness checks for large graphs
    ::testing::Values(Symmetrize_Usecase{false, false, false},
                      Symmetrize_Usecase{true, false, false},
                      Symmetrize_Usecase{false, true, false},
                      Symmetrize_Usecase{true, true, false}),
    ::testing::Values(
      cugraph::test::Rmat_Usecase(20, 32, 0.57, 0.19, 0.19, 0, false, false, 0, true))));

CUGRAPH_MG_TEST_PROGRAM_MAIN()
