<!-- English translation of docs/licences.md: the French version is authoritative. -->

# Licenses & Attributions

*Last updated: 18 November 2026*

*This is a translation. The [French version](../licences.md) is the authoritative one.*

Triva is built with open-source software, AI models and open data by other authors. Thank you to them. This page lists their licenses, as they require.

## 1. Triva

Triva's code is published under the **MIT license** (`LICENSE` file in the repository: https://github.com/Ben-126/Triva), “Copyright (c) 2026 Ben Podrojsky”.

## 2. Data sources

| Source | Used for | License | Credit |
|---|---|---|---|
| [Open-Meteo](https://open-meteo.com/) | Weather | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | Weather data by Open-Meteo.com (CC BY 4.0). Free service for non-commercial use ([terms](https://open-meteo.com/en/terms)). |
| [Wikipedia](https://www.wikipedia.org/) | Answer sources | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) | Wikipedia texts belong to their authors ([Wikimedia terms](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use)). Each source keeps its link to the article. |
| [Marginalia Search](https://marginalia-search.com/) | Answer sources | [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) | Results provided by Marginalia Search with its public key, for non-commercial use ([API](https://about.marginalia-search.com/article/api/)). |
| [OpenAlex](https://openalex.org/) | Scientific papers | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | Public-domain data ([OpenAlex](https://help.openalex.org/data/how-its-built/)). |
| [arXiv](https://arxiv.org/) | Scientific preprints | Metadata under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | Thank you to arXiv for open access to its metadata. Triva is not endorsed or supported by arXiv. Each paper keeps its own license. |

Web pages, images and videos shown in results belong to their authors. Triva shows a link to the original.

## 3. Discover tab

Triva shows news feeds from these publishers, following their reuse rules: a link to the full article, the outlet's name, content not modified.

| Publisher | Reuse rules |
|---|---|
| Numerama | [Legal notice](https://www.numerama.com/mentions-legales/). Numerama articles shown in Discover are never sent to an AI by Triva. |
| Frandroid | [Legal notice](https://www.frandroid.com/mentions-legales) |
| The Conversation | Articles under [CC BY-ND 4.0](https://creativecommons.org/licenses/by-nd/4.0/) ([republishing guidelines](https://theconversation.com/fr/republishing-guidelines)): author and site credited, text not modified. |
| ESPN | [RSS feed terms](https://www.espn.com/espn/news/story?page=rssinfo) |
| Variety, Deadline, The Hollywood Reporter, ARTnews (Penske Media) | [Terms of use](https://pmc.com/terms-of-use), § 19 "Content Feeds" |

## 4. Local AI models (MLX)

The **Qwen3 0.6B, Qwen3 1.7B, Qwen3 4B, Qwen3 8B, Qwen3 14B, Qwen3 30B-A3B, Qwen3 32B** models are created by the Qwen team at **Alibaba Cloud** and published under the **Apache 2.0 license** ("Copyright 2024 Alibaba Cloud"). Triva offers their 4-bit MLX conversions published by [mlx-community](https://huggingface.co/mlx-community) on Hugging Face. They are not included in the app: you download them if you choose to. Original models: [Qwen on Hugging Face](https://huggingface.co/Qwen). Apache 2.0 license text: section 6 of the [French page](../licences.md).

Apple Intelligence is an Apple service, subject to Apple's terms.

## 5. Open-source software included in Triva

| Component | Version | License | Copyright |
|---|---|---|---|
| [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels) | revision fd965bf (branch, no version) | Apache-2.0 | Copyright 2026 Anthropic PBC |
| [EventSource](https://github.com/mattt/EventSource) | 1.5.1 | MIT | Copyright 2025 Mattt (https://mat.tt) |
| [MLX Swift](https://github.com/ml-explore/mlx-swift) | 0.31.6 | MIT | Copyright (c) 2023 ml-explore |
| [MLX (bundled in Cmlx)](https://github.com/ml-explore/mlx) | version bundled with mlx-swift 0.31.6 | MIT | Copyright © 2023 Apple Inc. |
| [MLX C (bundled in Cmlx)](https://github.com/ml-explore/mlx-c) | version bundled with mlx-swift 0.31.6 | MIT | Copyright (c) 2023 ml-explore |
| [metal-cpp (bundled in Cmlx)](https://developer.apple.com/metal/cpp/) | metal-cpp_macOS15_iOS18-beta, with patch from mlx-swift | Apache-2.0 | Copyright © 2024 Apple Inc. |
| [{fmt}](https://github.com/fmtlib/fmt) | 12.1.0 | MIT | Copyright (c) 2012 - present, Victor Zverovich and {fmt} contributors |
| [JSON for Modern C++ (nlohmann/json)](https://github.com/nlohmann/json) | 3.11.3 | MIT | Copyright (c) 2013-2022 Niels Lohmann |
| [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) | revision 37688d2 (branch, no version) | MIT | Copyright (c) 2024 ml-explore |
| [XGrammar (bundled in mlx-swift-lm)](https://github.com/mlc-ai/xgrammar) | v0.1.30 | Apache-2.0 | Copyright (c) 2024 by XGrammar Contributors |
| [PicoJSON (bundled in XGrammar)](https://github.com/kazuho/picojson) | version bundled with XGrammar v0.1.30 | BSD-2-Clause | Copyright 2009-2010 Cybozu Labs, Inc. ; Copyright 2011-2014 Kazuho Oku |
| [DLPack (bundled in XGrammar)](https://github.com/dmlc/dlpack) | version bundled with XGrammar v0.1.30 | Apache-2.0 | Copyright (c) 2017 by Contributors |
| [Swift Hugging Face](https://github.com/huggingface/swift-huggingface) | 0.9.0 | Apache-2.0 | Copyright 2025 Hugging Face SAS. |
| [Swift Transformers](https://github.com/huggingface/swift-transformers) | 1.3.3 | Apache-2.0 | Copyright 2022 Hugging Face SAS. |
| [Swift Jinja](https://github.com/huggingface/swift-jinja) | 2.4.2 | Apache-2.0 | Copyright 2022 Hugging Face SAS. |
| [Swift Crypto](https://github.com/apple/swift-crypto) | 4.5.1 | Apache-2.0 | Copyright (c) 2019-2025 Apple Inc. and the SwiftCrypto project authors |
| [Swift ASN.1](https://github.com/apple/swift-asn1) | 1.7.1 | Apache-2.0 | Copyright 2022 The SwiftASN1 Project |
| [Swift Collections](https://github.com/apple/swift-collections) | 1.6.0 | Apache-2.0 + Runtime Library Exception | Copyright (c) 2021 - 2026 Apple Inc. and the Swift project authors |
| [Swift Numerics](https://github.com/apple/swift-numerics) | 1.1.1 | Apache-2.0 + Runtime Library Exception | Copyright (c) 2020-2025 Apple Inc. and the Swift Numerics project authors |
| [yyjson](https://github.com/ibireme/yyjson) | 0.12.0 | MIT | Copyright (c) 2020 YaoYuan <ibireme@gmail.com> |

Notes:
- XGrammar, PicoJSON and DLPack are bundled in MLX Swift LM; MLX, MLX C, metal-cpp, {fmt} and JSON for Modern C++ are bundled in MLX Swift.
- Swift Collections and Swift Numerics (Runtime Library Exception) and {fmt} (optional exception) don't require this credit: it is given as a courtesy.
- Swift ASN.1 was not found in the compiled app; it is listed as a precaution.
- Tools used only to build the app, not included: Swift Argument Parser, Swift Syntax.

## 6. License texts

The full license texts (MIT, BSD 2-Clause, Apache 2.0, Runtime Library Exception) and NOTICE files are reproduced in section 6 of the [French page](../licences.md). They are in English in both versions.
