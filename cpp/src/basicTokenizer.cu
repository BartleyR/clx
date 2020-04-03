#include <vector>
#include <string>

#include "cp_util.cuh"
#include "data_transfer_utils.cuh"
#include "cub/cub.cuh"
#include "tokenizer_utils.cuh"
#include "tokenizers.cuh"

#define SORT_BIT 22
#define THREADS_PER_BLOCK 64

/*
  Returns true if the byte passed in could be a valid head byte for
  a utf8 character.
*/
__device__ __forceinline__ bool is_head_byte(unsigned char utf8_byte){
  return (utf8_byte >> 6) != 2;
}


/*
  If the byte at start_byte_for_thread is a head byte, the unicode code-point encoded by
  the utf8 character started at that byte is returned and the head_byte boolean passed in
  is set to true.

  If the byte at start_byte_for_thread is not a head byte, 0 is returned AND the head_byte
  boolean passed in is set to false.

  All threads start reading bytes from the pointer denoted by sentences.

  Params
  --------
  sentences: A pointer to the start of the sequence of characters to be tokenized.
*/
__device__ __forceinline__ uint32_t extract_code_points_from_utf8(const unsigned char* sentences,
                                                                  const uint32_t start_byte_for_thread,
                                                                  bool& head_byte) {

  constexpr uint8_t max_utf8_blocks_for_char = 4;
  uint8_t utf8_blocks[max_utf8_blocks_for_char];

  #pragma unroll 
  for(int i = 0; i < max_utf8_blocks_for_char; ++i) {
    utf8_blocks[i] = sentences[start_byte_for_thread + i];
  }
  
  // We can have at most 5 bits encoding the length. We check those bits to infer the actual length
  const uint8_t length_encoding_bits = utf8_blocks[0] >> 3;

  head_byte = is_head_byte(utf8_blocks[0]);

  // Set the number of characters and the top masks based on the
  // length encoding bits.
  uint8_t char_encoding_length = 0, top_mask = 0;
  if (length_encoding_bits < 16){
    char_encoding_length = 1;
    top_mask = 0x7F;
  } else if (length_encoding_bits >= 24 && length_encoding_bits <= 27) {
    char_encoding_length = 2;
    top_mask = 0x1F;
  } else if (length_encoding_bits == 28 || length_encoding_bits == 29) {
    char_encoding_length = 3;
    top_mask = 0x0F;
  } else if (length_encoding_bits == 30) {
    char_encoding_length = 4;
    top_mask = 0x07;
  }

  // Now pack up the bits into a uint32_t. All threads will process 4 bytes
  // to reduce divergence.
  uint32_t code_point = (utf8_blocks[0] & top_mask) << 18;

  #pragma unroll
  for(int i = 1; i < 4; ++i) {
    code_point |= ((utf8_blocks[i] & 0x3F) << (18 - 6*i));
  }

  // Zero out the bottom of code points with extra reads
  const uint8_t shift_amt = 24 - 6*char_encoding_length;
  code_point >>= shift_amt;

  return code_point;
}

__global__ void gpuBasicTokenizer(const unsigned char* sentences,  uint32_t* device_sentence_offsets,
                                  const size_t total_bytes, uint32_t* cp_metadata, uint64_t* aux_table, 
                                  uint32_t* code_points, uint32_t* chars_per_thread, bool do_lower_case,
                                  uint32_t num_sentences) {

  constexpr uint32_t init_val = (1 << SORT_BIT);
  uint32_t replacement_code_points[MAX_NEW_CHARS] = {init_val, init_val, init_val};
  
  bool head_byte = false;
  const uint32_t char_for_thread = blockDim.x * blockIdx.x + threadIdx.x;
  uint32_t num_new_chars = 0;                                  

  if(char_for_thread < total_bytes){                                  
    const uint32_t code_point = extract_code_points_from_utf8(sentences, char_for_thread, head_byte);
    const uint32_t thr_cp_metadata = get_cp_metadata(cp_metadata, code_point);

    if(!should_remove_cp(thr_cp_metadata, do_lower_case) && head_byte) {
      num_new_chars = 1;
      // Apply lower cases and accent stripping if necessary
      const bool replacement_needed = do_lower_case || always_replace(thr_cp_metadata);
      uint32_t new_cp = replacement_needed? get_first_cp(thr_cp_metadata): code_point;
      new_cp = new_cp == 0? code_point: new_cp;

      replacement_code_points[0] = new_cp;
      if(is_multi_char_transform(thr_cp_metadata) && do_lower_case) {
        uint64_t next_cps = get_extra_cps(aux_table, code_point);
        replacement_code_points[1] = static_cast<uint32_t>(next_cps >> 32);
        const uint32_t potential_next_cp = static_cast<uint32_t>(next_cps);
        replacement_code_points[2] = potential_next_cp != 0? potential_next_cp: replacement_code_points[2];
        num_new_chars = 2 + (potential_next_cp != 0);
      }

      if(should_add_spaces(thr_cp_metadata, do_lower_case)){

        // Need to shift all existing code-points up one
        for(int loc = num_new_chars; loc > 0; --loc) {
          replacement_code_points[loc] = replacement_code_points[loc - 1];
        }

        // Write the required spaces at the end
        replacement_code_points[0] = SPACE_CODE_POINT;
        replacement_code_points[num_new_chars + 1] = SPACE_CODE_POINT;
        num_new_chars += 2;
      }
    }
  }

  chars_per_thread[char_for_thread] = num_new_chars;
    
  typedef cub::BlockStore<uint32_t, THREADS_PER_BLOCK, MAX_NEW_CHARS, cub::BLOCK_STORE_WARP_TRANSPOSE> BlockStore;
  __shared__ typename BlockStore::TempStorage temp_storage;

  // Now we perform coalesced writes back to global memory using cub.
  uint32_t* block_base = code_points + blockIdx.x * blockDim.x * MAX_NEW_CHARS;
  BlockStore(temp_storage).Store(block_base, replacement_code_points);
}


void transfer_cp_data_to_device(uint32_t **device_cp_metadata, uint64_t **device_aux_data) {
  malloc_and_copy_vec_to_device(device_cp_metadata, cp_data);
  malloc_and_copy_vec_to_device(device_aux_data, aux_data);
}


void flatten_sentences(const std::vector<std::string>& sentences,
                       char* flattened_sentences, 
                       uint32_t* sentence_offsets) {

  uint32_t start_copy = 0;
  for(int i = 0; i < sentences.size(); ++i){
    const uint32_t sentence_length = sentences[i].size();

    sentences[i].copy(flattened_sentences + start_copy, sentence_length);
    sentence_offsets[i] = start_copy;
    start_copy += sentence_length;
  }
  sentence_offsets[sentences.size()] = start_copy;
}


// -------------------------------------- Basic tokenizer definitions ------------------------------------------------------------
// See tokenizers.cuh

GpuBasicTokenizer::GpuBasicTokenizer(uint32_t max_num_sentences, uint32_t max_num_chars, bool do_lower_case):
  do_lower_case(do_lower_case), device_cp_metadata(nullptr), device_aux_table(nullptr) {
  transfer_cp_data_to_device(&device_cp_metadata, &device_aux_table);
  assertCudaSuccess(cudaMalloc(&device_sentence_offsets, sizeof(*device_sentence_offsets) * max_num_sentences + 1));
  assertCudaSuccess(cudaMalloc(&device_sentences, sizeof(*device_sentences) * max_num_chars));

  size_t max_BLOCKS = (max_num_chars + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
  size_t max_threads_on_device = max_BLOCKS * THREADS_PER_BLOCK;

  const size_t max_new_char_total = MAX_NEW_CHARS * max_threads_on_device;
  const size_t device_code_points_size = sizeof(*device_code_points) * max_new_char_total;
  assertCudaSuccess(cudaMalloc(&device_code_points, device_code_points_size));

  const size_t device_chars_per_thread_size = sizeof(*device_chars_per_thread) * max_threads_on_device;
  assertCudaSuccess(cudaMalloc(&device_chars_per_thread, device_chars_per_thread_size));

  // Determine temporary device storage requirements for cub
  size_t temp_storage_scan_bytes = 0;
  uint32_t* device_chars_per_thread = nullptr;
  cub::DeviceScan::InclusiveSum(nullptr, temp_storage_scan_bytes, device_chars_per_thread, device_chars_per_thread, max_threads_on_device);
  size_t temp_storage_select_bytes = 0;
  static NotEqual select_op((1 << SORT_BIT));
  cub::DeviceSelect::If(nullptr, temp_storage_select_bytes, device_code_points, device_code_points, 
                        device_num_selected, max_new_char_total, select_op);
  max_cub_storage_bytes = std::max(temp_storage_scan_bytes, temp_storage_select_bytes);
  assertCudaSuccess(cudaMalloc(&cub_temp_storage, max_cub_storage_bytes));
  const size_t device_num_selected_size = sizeof(*device_num_selected);
  assertCudaSuccess(cudaMalloc(&device_num_selected, device_num_selected_size));
}



std::pair<ptr_length_pair<uint32_t*>, ptr_length_pair<uint32_t*>> GpuBasicTokenizer::tokenize(const std::vector<std::string>& sentences) {

  ptr_length_pair<uint32_t*> cp_and_length;
  ptr_length_pair<uint32_t*> offset_and_length;

  size_t total_sentence_bytes = 0;                            
  for(const auto& sentence: sentences) {
    total_sentence_bytes += sentence.length();
  }

  size_t num_offsets = sentences.size() + 1;
  uint32_t* sentence_offsets = new uint32_t[num_offsets];
  char* flattened_sentences = new char[total_sentence_bytes];
  flatten_sentences(sentences, flattened_sentences, sentence_offsets);
  assertCudaSuccess(cudaMemcpy(device_sentence_offsets, sentence_offsets, sizeof(*device_sentence_offsets) * num_offsets, cudaMemcpyHostToDevice));
  assertCudaSuccess(cudaMemcpy(device_sentences, flattened_sentences, total_sentence_bytes, cudaMemcpyHostToDevice));

  static NotEqual select_op((1 << SORT_BIT));
  
  size_t BLOCKS = (total_sentence_bytes + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

  const size_t max_new_char_total = MAX_NEW_CHARS * BLOCKS * THREADS_PER_BLOCK;
  size_t threads_on_device = BLOCKS * THREADS_PER_BLOCK;

  gpuBasicTokenizer<<<BLOCKS, THREADS_PER_BLOCK>>>(device_sentences, device_sentence_offsets, total_sentence_bytes, device_cp_metadata, device_aux_table, 
                                                   device_code_points, device_chars_per_thread, do_lower_case, sentences.size()); 
  assertCudaSuccess(cudaPeekAtLastError());                                    

  cub::DeviceSelect::If(cub_temp_storage, max_cub_storage_bytes, device_code_points, device_code_points, device_num_selected, max_new_char_total, select_op);
  assertCudaSuccess(cudaPeekAtLastError());

  // We also need to prefix sum the number of characters up to an including the current character in order to get the new sentence lengths.
  cub::DeviceScan::InclusiveSum(cub_temp_storage, max_cub_storage_bytes, device_chars_per_thread, device_chars_per_thread, threads_on_device);  
  assertCudaSuccess(cudaPeekAtLastError());

  constexpr uint16_t SENTENCE_UPDATE_THREADS = 64;                              
  size_t SEN_KERNEL_BLOCKS = (sentences.size() + SENTENCE_UPDATE_THREADS - 1) / SENTENCE_UPDATE_THREADS;   
  update_sentence_lengths<<<SEN_KERNEL_BLOCKS, SENTENCE_UPDATE_THREADS>>>(device_sentence_offsets, device_chars_per_thread, sentences.size());
  assertCudaSuccess(cudaPeekAtLastError());   

  offset_and_length.gpu_ptr = device_sentence_offsets;
  offset_and_length.length = sentences.size() + 1;

  uint32_t num_chars = 0;
  assertCudaSuccess(cudaMemcpy(&num_chars, offset_and_length.gpu_ptr + sentences.size(), sizeof(num_chars), cudaMemcpyDeviceToHost));
  cp_and_length.gpu_ptr = device_code_points;
  cp_and_length.length = num_chars;
  
  return std::make_pair(cp_and_length, offset_and_length);
}

std::pair<ptr_length_pair<uint32_t*>, ptr_length_pair<uint32_t*>> GpuBasicTokenizer::tokenize(const char* device_sentences_, uint32_t* offsets, uint32_t offset_size)  {

  ptr_length_pair<uint32_t*> cp_and_length;
  ptr_length_pair<uint32_t*> offset_and_length;

  size_t num_offsets = offset_size + 1;
  uint32_t* sentence_offsets = new uint32_t[num_offsets];
  uint32_t start_copy = 0;
  for(int i = 0; i < offset_size; ++i){
    sentence_offsets[i] = start_copy;
    start_copy += offsets[i];
  }
  sentence_offsets[offset_size] = start_copy;

  assertCudaSuccess(cudaMemcpy(device_sentence_offsets, sentence_offsets, sizeof(*device_sentence_offsets) * num_offsets, cudaMemcpyHostToDevice));

  static NotEqual select_op((1 << SORT_BIT));

  size_t BLOCKS = (sentence_offsets[offset_size] + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

  const size_t max_new_char_total = MAX_NEW_CHARS * BLOCKS * THREADS_PER_BLOCK;
  size_t threads_on_device = BLOCKS * THREADS_PER_BLOCK;

  gpuBasicTokenizer<<<BLOCKS, THREADS_PER_BLOCK>>>((unsigned char*)device_sentences_, device_sentence_offsets, sentence_offsets[offset_size], device_cp_metadata, device_aux_table,
                                                   device_code_points, device_chars_per_thread, do_lower_case, offset_size);
  assertCudaSuccess(cudaPeekAtLastError());

  cub::DeviceSelect::If(cub_temp_storage, max_cub_storage_bytes, device_code_points, device_code_points, device_num_selected, max_new_char_total, select_op);
  assertCudaSuccess(cudaPeekAtLastError());

  // We also need to prefix sum the number of characters up to an including the current character in order to get the new sentence lengths.
  cub::DeviceScan::InclusiveSum(cub_temp_storage, max_cub_storage_bytes, device_chars_per_thread, device_chars_per_thread, threads_on_device);
  assertCudaSuccess(cudaPeekAtLastError());

  constexpr uint16_t SENTENCE_UPDATE_THREADS = 64;
  size_t SEN_KERNEL_BLOCKS = (offset_size + SENTENCE_UPDATE_THREADS - 1) / SENTENCE_UPDATE_THREADS;
  update_sentence_lengths<<<SEN_KERNEL_BLOCKS, SENTENCE_UPDATE_THREADS>>>(device_sentence_offsets, device_chars_per_thread, offset_size);
  assertCudaSuccess(cudaPeekAtLastError());

  offset_and_length.gpu_ptr = device_sentence_offsets;
  offset_and_length.length = offset_size + 1;

  uint32_t num_chars = 0;
  assertCudaSuccess(cudaMemcpy(&num_chars, offset_and_length.gpu_ptr + offset_size, sizeof(num_chars), cudaMemcpyDeviceToHost));
  cp_and_length.gpu_ptr = device_code_points;
  cp_and_length.length = num_chars;

  return std::make_pair(cp_and_length, offset_and_length);
}

GpuBasicTokenizer::~GpuBasicTokenizer() {
  assertCudaSuccess(cudaFree(device_aux_table));
  assertCudaSuccess(cudaFree(device_cp_metadata));
  assertCudaSuccess(cudaFree(device_sentences));
  assertCudaSuccess(cudaFree(device_sentence_offsets));
  assertCudaSuccess(cudaFree(device_code_points));
  assertCudaSuccess(cudaFree(device_chars_per_thread));
  assertCudaSuccess(cudaFree(device_num_selected));
  assertCudaSuccess(cudaFree(cub_temp_storage));
}
