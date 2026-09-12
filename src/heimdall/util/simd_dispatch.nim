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

## Startup ISA selection and specialization of the shared NNUE kernels.
import std/strutils
when defined(runtimeSimd):
    import std/macros

type SimdBackend* = enum
    sbScalar, sbSse2, sbSsse3, sbSse41, sbAvx2, sbAvx512, sbVnni, sbNeon

const backendNames*: array[SimdBackend, string] =
    ["scalar", "sse2", "ssse3", "sse41", "avx2", "avx512", "avx512-vnni", "neon"]

when defined(runtimeSimd):
    import std/os
    when defined(amd64):
        proc cpuInit() {.importc: "__builtin_cpu_init", nodecl.}
        proc cpuSupports(feature: cstring): cint {.importc: "__builtin_cpu_supports", nodecl.}

    elif not defined(arm64):
        {.fatal: "Universal SIMD supports x86-64 and AArch64".}

    proc detectBackends(): set[SimdBackend] =
        result = {sbScalar}
        when defined(amd64):
            # Compiler runtime detection checks OSXSAVE/XCR0 as well as CPUID.
            cpuInit()
            result.incl(sbSse2)
            if cpuSupports("ssse3") != 0: result.incl(sbSsse3)
            if cpuSupports("sse4.1") != 0: result.incl(sbSse41)
            if cpuSupports("avx2") != 0: result.incl(sbAvx2)
            if cpuSupports("avx512f") != 0 and cpuSupports("avx512bw") != 0:
                result.incl(sbAvx512)
                if cpuSupports("avx512vnni") != 0: result.incl(sbVnni)
        else:
            result.incl(sbNeon)

    let supportedBackends* = detectBackends()

    proc selectBackend(): SimdBackend =
        let requested = getEnv("HEIMDALL_SIMD", "auto").toLowerAscii()
        if requested != "auto":
            for backend in SimdBackend:
                if requested == backendNames[backend]:
                    if backend notin supportedBackends:
                        quit("heimdall: SIMD backend '" & requested & "' is unsupported by this CPU/OS", QuitFailure)
                    return backend
            quit("heimdall: unknown HEIMDALL_SIMD backend '" & requested & "'", QuitFailure)
        for backend in countdown(high(SimdBackend), low(SimdBackend)):
            if backend in supportedBackends: return backend

    # Immutable for the process lifetime: workers and pending accumulators all
    # share the same selection. Override it before startup, never during search.
    let processBackend = selectBackend()
else:
    const processBackend =
        when defined(avx512) and defined(vnni): sbVnni
        elif defined(avx512): sbAvx512
        elif defined(avx2): sbAvx2
        elif defined(sse41): sbSse41
        elif defined(ssse3): sbSsse3
        elif defined(sse2): sbSse2
        elif defined(neon): sbNeon
        else: sbScalar
    const supportedBackends* = {processBackend}

func activeBackend*(): SimdBackend {.inline.} =
    ## The immutable process configuration is safe to read from pure kernels.
    {.cast(noSideEffect).}:
        processBackend

proc printSimdInfo*() =
    ## Report the chosen backend and the backends usable by this executable.
    echo "SIMD backend: ", backendNames[activeBackend()]
    var names: seq[string]
    for backend in supportedBackends: names.add(backendNames[backend])
    echo "Supported SIMD backends: ", names.join(" ")


when defined(runtimeSimd):
    const backendModules = ["", "sse2", "ssse3", "sse41", "avx2", "avx512", "avx512_vnni", "neon"]

    proc backendSymbol(backend: SimdBackend, name: string): NimNode =
        newDotExpr(ident("runtime" & backendModules[backend.ord]), ident(name))

    proc specialize(node: NimNode, backend: SimdBackend): NimNode =
        if node.kind == nnkCall and node.len == 2 and node[0].eqIdent("defined"):
            let flag = node[1].strVal
            if flag in ["simd", "sse2", "ssse3", "sse41", "avx2", "avx512", "vnni", "neon"]:
                return newLit(case flag
                    of "simd": backend != sbScalar
                    of "sse2": backend == sbSse2
                    of "ssse3": backend == sbSsse3
                    of "sse41": backend == sbSse41
                    of "avx2": backend == sbAvx2
                    of "avx512": backend in {sbAvx512, sbVnni}
                    of "vnni": backend == sbVnni
                    else: backend == sbNeon)
        if node.kind == nnkIdent and backend != sbScalar:
            if (node.strVal.len > 3 and node.strVal.startsWith("vec") and node.strVal[3].isUpperAscii()) or node.strVal in
                    ["VEPI16", "VEPI32", "CHUNK_SIZE", "REGISTER_SIZE", "I16_CHUNK_SIZE", "I32_CHUNK_SIZE"]:
                return backendSymbol(backend, node.strVal)
        result = node.copyNimNode()
        for child in node: result.add(specialize(child, backend))


macro simdKernel*(definition: untyped): untyped =
    ## Compile the same body for each ISA, with one dispatch per whole operation.
    ## Vector types never cross the dispatch boundary. Static builds are unchanged.
    when not defined(runtimeSimd):
        return definition
    else:
        definition.expectKind({nnkProcDef, nnkFuncDef})
        let name = if definition[0].kind == nnkPostfix: definition[0][1].strVal else: definition[0].strVal
        let backends = when defined(amd64): @[sbScalar, sbSse2, sbSsse3, sbSse41, sbAvx2, sbAvx512, sbVnni]
                       else: @[sbScalar, sbNeon]
        const features = ["sse2", "sse2", "ssse3", "sse4.1", "avx2", "avx512f,avx512bw", "avx512f,avx512bw,avx512vnni", ""]
        result = newStmtList()
        for backend in backends:
            if backend == sbScalar: continue
            let module = backendModules[backend.ord]
            result.add(parseStmt("when not declared(runtime" & module & "):\n" &
                "    from heimdall/util/simd_backends/" & module & " as runtime" & module & " import nil"))
        let dispatch = newTree(nnkCaseStmt, newCall(bindSym"activeBackend"))
        for backend in backends:
            let variantName = ident(name & "_" & $backend)
            var variant = definition.copyNimTree()
            variant[0] = variantName
            variant[4] = newTree(nnkPragma)
            when defined(amd64):
                variant[4].add(newTree(nnkExprColonExpr, ident"codegenDecl",
                    newLit("__attribute__((target(\"" & features[backend.ord] & "\"))) $# $#$#")))
            variant[6] = specialize(definition[6], backend)
            # Small standalone arithmetic tests can have fewer lanes than the
            # selected ISA. Use scalar arithmetic for incompatible row strides.
            if backend != sbScalar:
                let lanes = newLit(case backend
                    of sbAvx2: 16
                    of sbAvx512, sbVnni: 32
                    else: 8)
                let scalarBody = specialize(definition[6], sbScalar)
                let vectorBody = variant[6]
                variant[6] = quote do:
                    when declared(O):
                        when O mod `lanes` == 0:
                            `vectorBody`
                        else:
                            `scalarBody`
                    elif declared(L1_SIZE):
                        when L1_SIZE mod `lanes` == 0:
                            `vectorBody`
                        else:
                            `scalarBody`
                    else:
                        `vectorBody`
            result.add(variant)
            let call = newCall(variantName)
            for param in definition[3][1..^1]:
                for i in 0..<param.len - 2: call.add(param[i].copyNimTree())
            let action = if definition[3][0].kind == nnkEmpty: call else: newTree(nnkReturnStmt, call)
            dispatch.add(newTree(nnkOfBranch, newLit(backend), newStmtList(action)))
        dispatch.add(newTree(nnkElse, newStmtList(newCall(bindSym"doAssert", newLit(false), newLit("uncompiled SIMD backend")))))
        var wrapper = definition.copyNimTree()
        wrapper[6] = newStmtList(dispatch)
        result.add(wrapper)
