when defined(linux):
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

    ## NUMA topology detection and best-effort thread binding.
    ##
    ## Adapted from Soul's NUMA support:
    ## - https://github.com/Aethdv/Soul/blob/soul/src/numa.rs
    ##
    ## Shamelessly yoinked with GPT 5.5 <3

    import std/[cpuinfo, options, strformat, strutils]


    type
        CPU = int

        CPUMask = object
            words: array[64, uint64]
            wordCount: int
            cpuCount: int

        NUMATopology* = object
            ## The machine's memory and cache locality domains, filtered to CPUs the
            ## current process is allowed to run on.
            nodes: seq[seq[CPU]]
            domains: seq[seq[CPU]]

        NUMABinding = object
            ## Fixed-size, unmanaged view of the detected topology for GC-safe thread
            ## binding.
            nodeCount: int
            domainCount: int
            nodes: array[256, CPUMask]
            domains: array[256, CPUMask]


    {.emit: """
    #include <stdint.h>

    #if defined(__linux__)
        #include <unistd.h>
        #include <sys/syscall.h>
    #endif

    NIM_EXTERNC int heimdall_process_affinity(uint64_t *mask, int words) {
    #if defined(__linux__) && defined(SYS_sched_getaffinity)
        long ret = syscall(SYS_sched_getaffinity, 0, (size_t)words * sizeof(uint64_t), mask);
        return ret >= 0;
    #else
        (void)mask;
        (void)words;
        return 0;
    #endif
    }

    NIM_EXTERNC int heimdall_bind_thread(const uint64_t *mask, int words) {
    #if defined(__linux__) && defined(SYS_sched_setaffinity)
        long ret = syscall(SYS_sched_setaffinity, 0, (size_t)words * sizeof(uint64_t), mask);
        if (ret != 0) {
            return 0;
        }
        #if defined(SYS_sched_yield)
            (void)syscall(SYS_sched_yield);
        #endif
        return 1;
    #else
        (void)mask;
        (void)words;
        return 0;
    #endif
    }
    """.}


    proc heimdallProcessAffinity(mask: ptr uint64, words: cint): cint {.importc: "heimdall_process_affinity", nodecl, gcsafe.}
    proc heimdallBindThread(mask: ptr uint64, words: cint): cint {.importc: "heimdall_bind_thread", nodecl, gcsafe.}


    func numNodes*(self: NUMATopology): int {.inline.} = self.nodes.len()
    func numDomains*(self: NUMATopology): int {.inline.} = self.domains.len()


    func shouldBind*(self: NUMATopology, threads: int): bool {.inline.} =
        ## Binding pays only when multiple search threads can be spread over
        ## multiple cache domains.
        self.domains.len() > 1 and threads > 1


    func shouldDistribute*(self: NUMATopology, threads: int): bool {.inline.} =
        ## A lone search thread wants local TT memory. Multi-threaded searches on
        ## multi-node systems benefit from striped first-touch placement.
        self.nodes.len() > 1 and threads > 1


    func parseCPUList*(s: string): seq[CPU] =
        ## Parses Linux cpulist syntax such as "0-15,128-143" or "0,2,4".
        for part in s.split(','):
            let part = part.strip()
            if part.len() == 0:
                continue
            let bounds = part.split('-', maxsplit=1)
            if bounds.len() == 2:
                try:
                    let
                        lo = bounds[0].parseInt()
                        hi = bounds[1].parseInt()
                    if lo <= hi:
                        for cpu in lo..hi:
                            result.add(cpu)
                except ValueError:
                    discard
            else:
                try:
                    result.add(part.parseInt())
                except ValueError:
                    discard


    func fill(occupied: int, domain: seq[CPU]): float {.inline.} =
        (occupied + 1).float / max(domain.len(), 1).float


    func distribute*(self: NUMATopology, threads: int): seq[int] =
        ## Assigns search threads to L3 domains, balancing by occupied/available CPU
        ## ratio so larger domains naturally receive more threads.
        var occupied = newSeq[int](max(self.domains.len(), 1))
        result = newSeqOfCap[int](threads)
        for _ in 0..<threads:
            var pick = 0
            if self.domains.len() > 0:
                var best = fill(occupied[0], self.domains[0])
                for i in 1..<self.domains.len():
                    let candidate = fill(occupied[i], self.domains[i])
                    if candidate < best:
                        pick = i
                        best = candidate
            inc(occupied[pick])
            result.add(pick)


    proc readTrimmed(path: string): Option[string] =
        try:
            return some(readFile(path).strip())
        except OSError:
            return none(string)


    proc processAffinity: Option[seq[CPU]] =
        var mask: array[64, uint64]
        if heimdallProcessAffinity(addr mask[0], mask.len().cint) == 0:
            return none(seq[CPU])

        var cpus: seq[CPU] = @[]
        for word, bits in mask:
            for bit in 0..<64:
                if (bits and (1'u64 shl bit)) != 0:
                    cpus.add(word * 64 + bit)
        some(cpus)


    proc allowedCPUs: seq[CPU] =
        let affinity = processAffinity()
        if affinity.isSome() and affinity.get().len() > 0:
            return affinity.get()

        let online = readTrimmed("/sys/devices/system/cpu/online")
        if online.isSome():
            let cpus = parseCPUList(online.get())
            if cpus.len() > 0:
                return cpus

        let count = countProcessors()
        for cpu in 0..<max(count, 1):
            result.add(cpu)


    proc readNUMANodes(allowed: seq[CPU]): Option[seq[seq[CPU]]] =
        let online = readTrimmed("/sys/devices/system/node/online")
        if online.isNone():
            return none(seq[seq[CPU]])

        var nodes: seq[seq[CPU]] = @[]
        for node in parseCPUList(online.get()):
            let cpulist = readTrimmed(&"/sys/devices/system/node/node{node}/cpulist")
            if cpulist.isNone():
                return none(seq[seq[CPU]])
            var cpus: seq[CPU] = @[]
            for cpu in parseCPUList(cpulist.get()):
                if cpu in allowed:
                    cpus.add(cpu)
            if cpus.len() > 0:
                nodes.add(cpus)

        if nodes.len() == 0:
            return none(seq[seq[CPU]])
        some(nodes)


    proc readL3Siblings(cpu: CPU): Option[string] =
        for index in 0..<8:
            let base = &"/sys/devices/system/cpu/cpu{cpu}/cache/index{index}"
            let level = readTrimmed(&"{base}/level")
            if level.isNone():
                break
            if level.get() == "3":
                return readTrimmed(&"{base}/shared_cpu_list")
        none(string)


    proc readL3Domains(allowed: seq[CPU]): Option[seq[seq[CPU]]] =
        var ceiling = 0
        for cpu in allowed:
            ceiling = max(ceiling, cpu + 1)

        var
            grouped = newSeq[bool](ceiling)
            domains: seq[seq[CPU]] = @[]

        for cpu in allowed:
            if cpu < grouped.len() and grouped[cpu]:
                continue
            let shared = readL3Siblings(cpu)
            if shared.isNone():
                return none(seq[seq[CPU]])

            var group: seq[CPU] = @[]
            for sibling in parseCPUList(shared.get()):
                if sibling in allowed:
                    group.add(sibling)
                    if sibling < grouped.len():
                        grouped[sibling] = true

            if group.len() > 0:
                domains.add(group)

        if domains.len() == 0:
            return none(seq[seq[CPU]])
        some(domains)


    proc detectNUMATopology*: NUMATopology =
        ## Detects NUMA memory nodes and L3 cache domains from Linux /sys. If any
        ## required topology read fails, the engine falls back to a single domain.
        let allowed = allowedCPUs()
        # ♪ numa numa numa iei ♪
        let nodes = readNUMANodes(allowed)
        if nodes.isSome():
            result.nodes = nodes.get()
        else:
            result.nodes = @[allowed]

        let domains = readL3Domains(allowed)
        if domains.isSome():
            result.domains = domains.get()
        else:
            result.domains = result.nodes


    proc bindThread(cpus: seq[CPU]): bool =
        if cpus.len() == 0:
            return false

        var highest = 0
        for cpu in cpus:
            highest = max(highest, cpu)

        let words = highest div 64 + 1
        var mask = newSeq[uint64](words)
        for cpu in cpus:
            if cpu >= 0:
                mask[cpu div 64] = mask[cpu div 64] or (1'u64 shl (cpu mod 64))

        heimdallBindThread(addr mask[0], words.cint) != 0


    proc bindToDomain*(self: NUMATopology, domain: int): bool =
        if domain notin 0..<self.domains.len():
            return false
        bindThread(self.domains[domain])


    proc bindToNode*(self: NUMATopology, node: int): bool =
        if node notin 0..<self.nodes.len():
            return false
        bindThread(self.nodes[node])


    func toCPUMask(cpus: seq[CPU]): CPUMask =
        var highest = -1
        for cpu in cpus:
            if cpu in 0..<result.words.len() * 64:
                result.words[cpu div 64] = result.words[cpu div 64] or (1'u64 shl (cpu mod 64))
                result.cpuCount += 1
                highest = max(highest, cpu)
        result.wordCount = max(highest div 64 + 1, 1)


    proc detectNUMABinding: NUMABinding =
        let topology = detectNUMATopology()
        result.nodeCount = min(topology.nodes.len(), result.nodes.len())
        result.domainCount = min(topology.domains.len(), result.domains.len())
        for i in 0..<result.nodeCount:
            result.nodes[i] = toCPUMask(topology.nodes[i])
        for i in 0..<result.domainCount:
            result.domains[i] = toCPUMask(topology.domains[i])


    let detectedBinding = detectNUMABinding()


    func maskCPUCount(mask: CPUMask): int {.inline.} = max(mask.cpuCount, 1)


    proc bindMask(mask: ptr CPUMask): bool {.gcsafe.} =
        if mask == nil or mask.cpuCount == 0:
            return false
        heimdallBindThread(unsafeAddr mask.words[0], mask.wordCount.cint) != 0


    proc NUMANodeCount*: int {.inline, gcsafe.} = detectedBinding.nodeCount
    proc NUMADomainCount*: int {.inline, gcsafe.} = detectedBinding.domainCount
    proc NUMAShouldBind*(threads: int): bool {.inline, gcsafe.} = detectedBinding.domainCount > 1 and threads > 1
    proc NUMAShouldDistribute*(threads: int): bool {.inline, gcsafe.} = detectedBinding.nodeCount > 1 and threads > 1


    proc NUMANodeForThread*(threadId, threads: int): int {.gcsafe.} =
        ## Returns the NUMA memory node assignment for an init worker without allocating.
        if threadId notin 0..<threads or detectedBinding.nodeCount == 0:
            return -1

        var occupied: array[256, int]
        for t in 0..threadId:
            var pick = 0
            for node in 1..<detectedBinding.nodeCount:
                let
                    lhs = (occupied[node] + 1) * detectedBinding.nodes[pick].maskCPUCount()
                    rhs = (occupied[pick] + 1) * detectedBinding.nodes[node].maskCPUCount()
                if lhs < rhs:
                    pick = node
            inc(occupied[pick])
            if t == threadId:
                return pick
        -1


    proc NUMADomainForThread*(threadId, threads: int): int {.gcsafe.} =
        ## Returns the L3 domain assignment for a search thread without allocating.
        if threadId notin 0..<threads or detectedBinding.domainCount == 0:
            return -1

        var occupied: array[256, int]
        for t in 0..threadId:
            var pick = 0
            for domain in 1..<detectedBinding.domainCount:
                let
                    lhs = (occupied[domain] + 1) * detectedBinding.domains[pick].maskCPUCount()
                    rhs = (occupied[pick] + 1) * detectedBinding.domains[domain].maskCPUCount()
                if lhs < rhs:
                    pick = domain
            inc(occupied[pick])
            if t == threadId:
                return pick
        -1


    proc bindToNUMADomain*(domain: int): bool {.inline, gcsafe.} =
        if domain notin 0..<detectedBinding.domainCount:
            return false
        bindMask(unsafeAddr detectedBinding.domains[domain])


    proc bindToNUMANode*(node: int): bool {.inline, gcsafe.} =
        if node notin 0..<detectedBinding.nodeCount:
            return false
        bindMask(unsafeAddr detectedBinding.nodes[node])


    func CPUList(first, last: CPU): seq[CPU] =
        for cpu in first..last:
            result.add(cpu)


    func countAssignments(assignment: seq[int], domain: int): int =
        for assigned in assignment:
            if assigned == domain:
                inc(result)


    proc basicTests* =
        ## Ported from Soul's NUMA test suite:
        ## https://github.com/Aethdv/Soul/blob/soul/src/numa.rs
        doAssert parseCPUList("0-3") == @[0, 1, 2, 3]
        doAssert parseCPUList("0,2,4") == @[0, 2, 4]
        doAssert parseCPUList("") == @[]

        # EPYC 9654 node 0: physical cores plus their SMT siblings, two blocks.
        let cpus = parseCPUList("0-95,192-287")
        doAssert cpus.len() == 192
        doAssert cpus[0] == 0
        doAssert cpus[^1] == 287
        doAssert 96 notin cpus

        let balanced = NUMATopology(nodes: @[CPUList(0, 31)], domains: @[CPUList(0, 15), CPUList(16, 31)])
        let assignment = balanced.distribute(4)
        doAssert countAssignments(assignment, 0) == 2
        doAssert countAssignments(assignment, 1) == 2

        let single = NUMATopology(nodes: @[CPUList(0, 7)], domains: @[CPUList(0, 7)])
        doAssert not single.shouldBind(8)
        doAssert single.distribute(4) == @[0, 0, 0, 0]

        let topology = detectNUMATopology()
        doAssert topology.numNodes() >= 1
        doAssert topology.numDomains() >= 1
else:
    type
        NUMATopology* = object


    func numNodes*(self: NUMATopology): int {.inline.} = 1
    func numDomains*(self: NUMATopology): int {.inline.} = 1


    func shouldBind*(self: NUMATopology, threads: int): bool {.inline.} = false
    func shouldDistribute*(self: NUMATopology, threads: int): bool {.inline.} = false


    func parseCPUList*(s: string): seq[int] = @[]


    func distribute*(self: NUMATopology, threads: int): seq[int] =
        result = newSeq[int](threads)


    proc detectNUMATopology*: NUMATopology =
        discard


    proc bindToDomain*(self: NUMATopology, domain: int): bool =
        false


    proc bindToNode*(self: NUMATopology, node: int): bool =
        false


    proc NUMANodeCount*: int {.inline, gcsafe.} = 1
    proc NUMADomainCount*: int {.inline, gcsafe.} = 1
    proc NUMAShouldBind*(threads: int): bool {.inline, gcsafe.} = false
    proc NUMAShouldDistribute*(threads: int): bool {.inline, gcsafe.} = false


    proc NUMANodeForThread*(threadId, threads: int): int {.gcsafe.} =
        -1


    proc NUMADomainForThread*(threadId, threads: int): int {.gcsafe.} =
        -1


    proc bindToNUMADomain*(domain: int): bool {.inline, gcsafe.} = false


    proc bindToNUMANode*(node: int): bool {.inline, gcsafe.} = false


    proc basicTests* =
        discard
