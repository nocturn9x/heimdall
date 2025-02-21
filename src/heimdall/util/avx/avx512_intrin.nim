type
  M512i* {.importc: "__m512i", header: "immintrin.h", bycopy.} = object

{.push header: "immintrin.h".}

func mm512_add_epi32*(a, b: M512i): M512i {.importc: "_mm512_add_epi32".}

func mm512_loadu_si512(p: ptr M512i): M512i {.importc: "_mm512_loadu_si512".}

template mm512_loadu_si512*(p: pointer): M512i =
  mm512_loadu_si512(cast[ptr M512i](p))

func mm512_madd_epi16*(a, b: M512i): M512i {.importc: "_mm512_madd_epi16".}

func mm512_max_epi16*(a, b: M512i): M512i {.importc: "_mm512_max_epi16".}

func mm512_min_epi16*(a, b: M512i): M512i {.importc: "_mm512_min_epi16".}

func mm512_mullo_epi16*(a, b: M512i): M512i {.importc: "_mm512_mullo_epi16".}

func mm512_set1_epi16*(a: int16 | uint16): M512i {.importc: "_mm512_set1_epi16".}

func mm512_setzero_si512*(): M512i {.importc: "_mm512_setzero_si512".}

func mm512_reduce_add_epi32*(a: M512i): int32 {.importc: "_mm512_reduce_add_epi32".}
