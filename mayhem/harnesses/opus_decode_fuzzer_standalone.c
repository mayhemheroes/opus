/* opus_decode_fuzzer_standalone.c — run-once reproducer driver for opus_decode_fuzzer.
 *
 * Reads a single input file and feeds it to LLVMFuzzerTestOneInput() exactly once. No libFuzzer
 * runtime is linked, so a crash yields a natural backtrace under ASan/UBSan. Used both for crash
 * reproduction and by scripts that replay a single test case.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
    return 1;
  }
  FILE *f = fopen(argv[1], "rb");
  if (f == NULL) {
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
  uint8_t *data = (uint8_t *)malloc((size_t)size ? (size_t)size : 1);
  if (data == NULL) {
    fclose(f);
    return 3;
  }
  if (size > 0 && fread(data, (size_t)size, 1, f) != 1) {
    fprintf(stderr, "read failed\n");
    free(data);
    fclose(f);
    return 4;
  }
  fclose(f);
  LLVMFuzzerTestOneInput(data, (size_t)size);
  free(data);
  return 0;
}
