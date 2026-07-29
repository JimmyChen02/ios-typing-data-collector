# Third-party notices

## SymSpell English frequency dictionary

This project includes a transformed subset of
`SymSpell/frequency_dictionary_en_82_765.txt` from
[wolfgarbe/SymSpell](https://github.com/wolfgarbe/SymSpell), pinned to commit
`c239062ae02961df18ab7da1671d01b4388204e0`.

The SymSpell project explains that the English frequency dictionary was created
by intersecting:

1. Google Books Ngram data, which supplies representative word frequencies and
   is distributed under the
   [Creative Commons Attribution 3.0 Unported License](https://creativecommons.org/licenses/by/3.0/).
2. SCOWL (Spell Checker Oriented Word Lists), which filters the data to genuine
   English vocabulary.

Google Books Ngram attribution:

> Google Books Ngram Corpus, Google LLC.

SCOWL collective work copyright:

> Copyright 2000-2018 by Kevin Atkinson.
>
> Permission to use, copy, modify, distribute and sell these word lists, the
> associated scripts, the output created from the scripts, and its
> documentation for any purpose is hereby granted without fee, provided that
> the above copyright notice appears in all copies and that both that copyright
> notice and this permission notice appear in supporting documentation.

SCOWL includes material from additional permissive and public-domain sources.
The complete current notice is available from the
[SCOWL README](https://wordlist.aspell.net/scowl-readme/).

SymSpell software is copyright Wolf Garbe and distributed under the MIT
License. No SymSpell software code is embedded in the keyboard; attribution is
included because the source dictionary is distributed through that project.

The bundled `TypingResearchShared/symspell_en_30k.tsv` is a deterministic
transformation containing the 30,000 highest-frequency unique entries. Its
generator and exact source/checksum metadata are in
`scripts/generate_symspell_english_model.py`.
