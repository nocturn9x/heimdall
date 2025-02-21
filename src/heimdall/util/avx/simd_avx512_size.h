#include <stdint.h>
#include <immintrin.h>

const int CHUNK_SIZE = sizeof(__m512i) / sizeof(int16_t);
