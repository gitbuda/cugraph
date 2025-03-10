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

#include "c_test_utils.h" /* RUN_TEST */

#include <cugraph_c/algorithms.h>
#include <cugraph_c/graph.h>

#include <math.h>

typedef int32_t vertex_t;
typedef int32_t edge_t;
typedef float weight_t;

int generic_pagerank_test(vertex_t* h_src,
                          vertex_t* h_dst,
                          weight_t* h_wgt,
                          weight_t* h_result,
                          size_t num_vertices,
                          size_t num_edges,
                          bool_t store_transposed,
                          double alpha,
                          double epsilon,
                          size_t max_iterations)
{
  int test_ret_value = 0;

  cugraph_error_code_t ret_code = CUGRAPH_SUCCESS;
  cugraph_error_t* ret_error;

  cugraph_resource_handle_t* p_handle = NULL;
  cugraph_graph_t* p_graph            = NULL;
  cugraph_pagerank_result_t* p_result = NULL;

  p_handle = cugraph_create_resource_handle();
  TEST_ASSERT(test_ret_value, p_handle != NULL, "resource handle creation failed.");

  ret_code = create_test_graph(
    p_handle, h_src, h_dst, h_wgt, num_edges, store_transposed, &p_graph, &ret_error);

  TEST_ASSERT(test_ret_value, ret_code == CUGRAPH_SUCCESS, "create_test_graph failed.");

  ret_code = cugraph_pagerank(
    p_handle, p_graph, NULL, alpha, epsilon, max_iterations, FALSE, FALSE, &p_result, &ret_error);
  TEST_ASSERT(test_ret_value, ret_code == CUGRAPH_SUCCESS, "cugraph_pagerank failed.");

  cugraph_type_erased_device_array_t* vertices;
  cugraph_type_erased_device_array_t* pageranks;

  vertices  = cugraph_pagerank_result_get_vertices(p_result);
  pageranks = cugraph_pagerank_result_get_pageranks(p_result);

  vertex_t h_vertices[num_vertices];
  weight_t h_pageranks[num_vertices];

  ret_code = cugraph_type_erased_device_array_copy_to_host(
    p_handle, (byte_t*)h_vertices, vertices, &ret_error);
  TEST_ASSERT(test_ret_value, ret_code == CUGRAPH_SUCCESS, "copy_to_host failed.");

  ret_code = cugraph_type_erased_device_array_copy_to_host(
    p_handle, (byte_t*)h_pageranks, pageranks, &ret_error);
  TEST_ASSERT(test_ret_value, ret_code == CUGRAPH_SUCCESS, "copy_to_host failed.");

  for (int i = 0; (i < num_vertices) && (test_ret_value == 0); ++i) {
    TEST_ASSERT(test_ret_value,
                nearlyEqual(h_result[h_vertices[i]], h_pageranks[i], 0.001),
                "pagerank results don't match");
  }

  cugraph_pagerank_result_free(p_result);
  cugraph_sg_graph_free(p_graph);
  cugraph_free_resource_handle(p_handle);
  cugraph_error_free(ret_error);

  return test_ret_value;
}

int test_pagerank()
{
  size_t num_edges    = 8;
  size_t num_vertices = 6;

  vertex_t h_src[]    = {0, 1, 1, 2, 2, 2, 3, 4};
  vertex_t h_dst[]    = {1, 3, 4, 0, 1, 3, 5, 5};
  weight_t h_wgt[]    = {0.1f, 2.1f, 1.1f, 5.1f, 3.1f, 4.1f, 7.2f, 3.2f};
  weight_t h_result[] = {0.0915528, 0.168382, 0.0656831, 0.191468, 0.120677, 0.362237};

  double alpha          = 0.95;
  double epsilon        = 0.0001;
  size_t max_iterations = 20;

  // Pagerank wants store_transposed = TRUE
  return generic_pagerank_test(
    h_src, h_dst, h_wgt, h_result, num_vertices, num_edges, TRUE, alpha, epsilon, max_iterations);
}

int test_pagerank_with_transpose()
{
  size_t num_edges    = 8;
  size_t num_vertices = 6;

  vertex_t h_src[]    = {0, 1, 1, 2, 2, 2, 3, 4};
  vertex_t h_dst[]    = {1, 3, 4, 0, 1, 3, 5, 5};
  weight_t h_wgt[]    = {0.1f, 2.1f, 1.1f, 5.1f, 3.1f, 4.1f, 7.2f, 3.2f};
  weight_t h_result[] = {0.0915528, 0.168382, 0.0656831, 0.191468, 0.120677, 0.362237};

  double alpha          = 0.95;
  double epsilon        = 0.0001;
  size_t max_iterations = 20;

  // Pagerank wants store_transposed = TRUE
  //    This call will force cugraph_pagerank to transpose the graph
  //    But we're passing src/dst backwards so the results will be the same
  return generic_pagerank_test(
    h_dst, h_src, h_wgt, h_result, num_vertices, num_edges, FALSE, alpha, epsilon, max_iterations);
}

/******************************************************************************/

int main(int argc, char** argv)
{
  int result = 0;
  result |= RUN_TEST(test_pagerank);
  result |= RUN_TEST(test_pagerank_with_transpose);
  return result;
}
