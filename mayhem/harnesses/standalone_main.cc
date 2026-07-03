// standalone_main.cc — a libFuzzer-free run-once driver for the sentencepiece
// harnesses, used to build the `-standalone` reproducer binaries. It reads a
// single input file named on argv[1], feeds its bytes to
// LLVMFuzzerTestOneInput once, and exits. If the harness defines
// LLVMFuzzerInitialize (e.g. processor_text_fuzzer loads its embedded model
// there), it is called first. This mirrors $STANDALONE_FUZZ_MAIN but is baked
// into the repo so the build is hermetic.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

// Weakly referenced: present only in harnesses that define it.
extern "C" __attribute__((weak)) int LLVMFuzzerInitialize(int *argc,
                                                          char ***argv);

int main(int argc, char **argv) {
  if (LLVMFuzzerInitialize) {
    LLVMFuzzerInitialize(&argc, &argv);
  }
  if (argc != 2) {
    fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
    return 1;
  }
  FILE *f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "failed to open %s\n", argv[1]);
    return 2;
  }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (size < 0) {
    fclose(f);
    return 3;
  }
  std::vector<uint8_t> buf(static_cast<size_t>(size));
  size_t got = size ? fread(buf.data(), 1, static_cast<size_t>(size), f) : 0;
  fclose(f);
  if (size && got != static_cast<size_t>(size)) {
    fprintf(stderr, "short read\n");
    return 4;
  }
  LLVMFuzzerTestOneInput(buf.data(), buf.size());
  return 0;
}
