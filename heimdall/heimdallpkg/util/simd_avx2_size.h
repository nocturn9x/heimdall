#include <stdint.h>
#include <immintrin.h>

const int CHUNK_SIZE = sizeof(__m256i) / sizeof(int16_t);