// Host-only subset of the pinned generated PartitionAlloc buildflags.
// engine.lock.json Chromium 157.0.8103.78 enables USE_PARTITION_ALLOC_AS_MALLOC.
// The exact upstream early-registration source reads only this one flag.
#ifndef ARX_BOOTSTRAP_PARTITION_ALLOC_BUILDFLAGS_H
#define ARX_BOOTSTRAP_PARTITION_ALLOC_BUILDFLAGS_H
#define PA_BUILDFLAG_INTERNAL_USE_PARTITION_ALLOC_AS_MALLOC() (1)
#define PA_BUILDFLAG(flag) (PA_BUILDFLAG_INTERNAL_##flag())
#endif
