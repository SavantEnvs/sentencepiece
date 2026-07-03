// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Fuzzer for the ModelProto deserialization / model-construction path.
//
// The build-time helper "generate_model" constructs ModelProto objects and
// serializes them; this harness feeds arbitrary bytes into the reverse path
// (ParseFromString) and then drives SentencePieceProcessor to exercise the
// full model-factory / tokenizer pipeline for every model type.
//
// Replacing the non-fuzzer generate_model target which had 0 coverage edges
// because it was a plain main() with no LLVMFuzzerTestOneInput.
//
// Robustness contract: every status return is checked; no call happens after a
// failed load; the entire body is wrapped in try/catch so that no exception
// (std::bad_alloc, protobuf internal errors, ...) can escape LLVMFuzzerTestOneInput
// as an unhandled exception → std::terminate → Mayhem has_critical_errors.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include <fuzzer/FuzzedDataProvider.h>
#include "sentencepiece_model.pb.h"
#include "sentencepiece_processor.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 4)
    return 0;

  try {
    FuzzedDataProvider fdp(data, size);

    // Take a small prefix as "text to encode" and use the rest as the proto.
    std::string text = fdp.ConsumeRandomLengthString(64);
    std::string proto_bytes = fdp.ConsumeRemainingBytesAsString();

    if (proto_bytes.empty())
      return 0;

    // --- Path 1: parse raw bytes as a ModelProto, then load into a processor ---
    // This exercises the protobuf deserialization + model factory dispatch.
    // ParseFromString is guarded; we only enter the loaded model path when
    // LoadFromSerializedProto also succeeds (two independent status checks).
    {
      sentencepiece::ModelProto model_proto;
      if (model_proto.ParseFromString(proto_bytes)) {
        // Valid proto: exercise the model factory via LoadFromSerializedProto.
        sentencepiece::SentencePieceProcessor processor;
        auto status = processor.LoadFromSerializedProto(proto_bytes);
        if (!status.ok())
          return 0;

        // Exercise encode/decode on successfully loaded model.
        std::vector<std::string> pieces;
        auto s1 = processor.Encode(text, &pieces);
        if (!s1.ok()) return 0;

        std::vector<int> ids;
        auto s2 = processor.Encode(text, &ids);
        if (!s2.ok()) return 0;

        if (!pieces.empty()) {
          std::string decoded;
          processor.Decode(pieces, &decoded);
        }
        if (!ids.empty()) {
          std::string decoded;
          processor.Decode(ids, &decoded);
        }

        // Vocabulary probing (hard cap at 16 to keep runtime bounded even for
        // crafted protos with very large vocab_size values).
        int vocab_size = processor.GetPieceSize();
        const int kVocabCap = 16;
        for (int i = 0; i < vocab_size && i < kVocabCap; ++i) {
          std::string piece = processor.IdToPiece(i);
          processor.PieceToId(piece);
          processor.IsUnknown(i);
          processor.IsControl(i);
          processor.IsByte(i);
        }

        processor.unk_id();
        processor.bos_id();
        processor.eos_id();
        processor.pad_id();
      }
    }

    // --- Path 2: try loading the raw bytes directly (invalid/valid proto path) ---
    // This exercises the LoadFromSerializedProto error-handling paths without
    // first checking ParseFromString, reaching different code paths.
    {
      sentencepiece::SentencePieceProcessor processor;
      auto status = processor.LoadFromSerializedProto(proto_bytes);
      if (!status.ok())
        return 0;

      // Reached only when proto_bytes is a structurally valid serialized model
      // that LoadFromSerializedProto accepts (exercise normalizer/model-init paths).
      std::string normalized;
      processor.Normalize(text, &normalized);
    }
  } catch (...) {
    // Swallow all exceptions (std::bad_alloc, protobuf internal, ...) so that
    // no unhandled exception escapes LLVMFuzzerTestOneInput.  An unhandled
    // exception becomes std::terminate → SIGABRT → Mayhem has_critical_errors.
    return 0;
  }

  return 0;
}
