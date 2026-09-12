# Copyright 2026 Mattia Giambirtone & All Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

## Static backend facade. Universal kernels bind their own backend explicitly.
when defined(avx512):
    when defined(vnni):
        import simd_backends/avx512_vnni
        export avx512_vnni
    else:
        import simd_backends/avx512
        export avx512
elif defined(avx2):
    import simd_backends/avx2
    export avx2
elif defined(sse41):
    import simd_backends/sse41
    export sse41
elif defined(ssse3):
    import simd_backends/ssse3
    export ssse3
elif defined(sse2):
    import simd_backends/sse2
    export sse2
elif defined(neon):
    import simd_backends/neon
    export neon
else:
    const
        CHUNK_SIZE* = 1
        REGISTER_SIZE* = 1
        I16_CHUNK_SIZE* = 0
        I32_CHUNK_SIZE* = 0
