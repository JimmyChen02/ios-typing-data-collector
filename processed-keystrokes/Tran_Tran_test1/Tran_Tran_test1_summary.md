# Tran_Tran_test1 — substitution summary

- keystroke rows: 217
  - inserts: 193
  - backspaces/deletes: 15
    - whole-selection deletes (select word + delete): 0
  - substitutions: 9

## substitutions by mechanism
- autocorrect: 6
  - contraction: 3
  - capitalization: 2
  - spelling: 1
  - outcome: kept: 6
- suggestion bar taps: 3
  - completion: 3
  - outcome: kept: 3
- inline predictions (space-accepted): 0
- manual overtypes: 0
- smart typography: 0
- unknown: 0

## episodes
- autocorrect · capitalization · kept: 2
    i → I
    Lol → lol
- autocorrect · contraction · kept: 3
    its → it's  (×2)
    ithacas → Ithaca's
- autocorrect · spelling · kept: 1
    coler → cooler
- suggestion bar taps · completion · kept: 3
    act → actually
    prett → pretty
    wea → weather

## calibration
- gap threshold: 8.751 ms (anchored_high; anchors 1 low / 5 high)

<details><summary>label definitions</summary>

- mechanism:
  - autocorrect: *iOS changed the word itself when a space/delimiter was typed*
  - suggestion bar taps: *user tapped a word in the bar above the keyboard*
  - inline predictions (space-accepted): *grey ghost text accepted by typing space*
  - manual overtypes: *user selected text and typed/pasted over it*
  - smart typography: *straight quote/dash auto-swapped for curly*
  - unknown: *no rule matched*
- effect:
  - capitalization: *case change only (i → I)*
  - punctuation: *punctuation swapped (' → ’) or written over a space (double-space → '. ')*
  - contraction: *apostrophe added (its → it's)*
  - completion: *typed prefix extended (act → actually)*
  - spacing: *space added/removed*
  - spelling: *letters corrected (coler → cooler)*
  - other: *anything else*
- outcome:
  - kept: *user never touched it again*
  - reverted_to_original: *user deleted it and retyped exactly what they had*
  - replaced_with_other: *user deleted it and typed something else*
  - deleted_entirely: *user deleted it and left nothing*
  - edited_after: *user changed it but did not remove it*
  - (not resolved): *session log had a gap; not certifiable*
- grey-zone rows: *timing ambiguous, review before trusting*

</details>
