# per-word edit metrics — Jimmy_test_Tran

Purpose of this export: (1) compute typing performance metrics (CER/WER, per-word edit rates); (2) serve as behavioral ground truth for evaluating the adaptive (Gaussian) keyboard.

## words
- total words (final text): 33
- total characters (final text): 153
- edited words: 7 (21.2%)
- untouched words: 26 (78.8%)
- edit events per 100 words: 54.5
- edit events per 100 characters: 11.8

## edited words by mechanism
A word may carry more than one mechanism, so mechanism counts can sum past the edited-word total.
- backspace_retype: 3 words (9.1% of all words, 42.9% of edited words)
    examples: `bread`, `basic`, `say`
- select_overtype: 1 words (3.0% of all words, 14.3% of edited words)
    examples: `day → d`
- autocorrect: 5 words (15.2% of all words, 71.4% of edited words)
    examples: `i → I`, `breadS → breads`, `its → it's`

<details><summary>mechanism definitions</summary>

- `backspace_retype` — user deleted characters (backspace or selection delete) and retyped
- `select_overtype` — user selected text and typed/pasted over it
- `smart_typography` — iOS smart punctuation rewrote characters
- `suggestion_bar` — user tapped a word on the suggestion bar
- `inline_prediction` — user accepted inline predictive text
- `autocorrect` — iOS autocorrect changed the word at a delimiter
- `unknown_substitution` — a substitution whose mechanism could not be attributed

</details>
