# 2026-08-13 — Can the bar-tap vs inline-prediction split be made mechanical?

Audit only. **No code changed, no build run.** Question asked: does the in-app
touch capture path let us identify a QuickType bar tap or an accepted inline
prediction at capture time, so `substitution_kind` stops being inferred?

Answer: **no at capture time — but the offline evidence is better than the
inter-key-interval threshold we were about to ship.**

## 1. The frozen touch in `Tran_test2_cursor.csv` is correct behaviour, not a bug

All 276 rows carry `touch_x=267.667, touch_y=270.667, touch_phase=ended,
tap_count=1`, with `touch_age_ms` climbing 1297.4 → 60436.4.

The capture path is wired correctly end to end:

| Link | Where | Verified |
|---|---|---|
| Overlay window *is* the app window | `SceneDelegate.swift:15-18` — `TouchOverlayWindow(windowScene:)`, `rootViewController = UIHostingController(rootView: ContentView())`, `makeKeyAndVisible()` | yes, it is the only window |
| Every touch phase reaches the tracker | `TouchOverlayWindow.swift:36-53` — `sendEvent` → `LastTouchTracker.record(point:phase:tapCount:)` | yes |
| Gate is open for the whole session | `RippleController.isRecording` set true in `NotepadView.startRecording`, cleared in `stopRecording` / `abortSession` / `handleDisappear` | yes |
| Tracker is cleared per session | `SessionRecorder.swift:80` → `LastTouchTracker.shared.reset()` | yes — no stale touch carries over |

**The decisive evidence that it is "correctly recorded nothing" and not
"silently recording nothing": the tracker did fire, once.** The row carries a
real converted text-view coordinate, `phase="ended"` (so both `.began` and
`.ended` were seen, latest winning) and `tap_count=1`. Row 1 is at
`t_ms=3436.5` with `touch_age_ms=1297.4`, putting the touch at **t ≈ 2139 ms** —
the participant's tap to focus the text view, a second after recording started.
A silently-dead path would have written empty `touch_*` columns
(`LoggingTextView.swift:151` guards on `latest` being non-nil), not one
well-formed sample.

Exactly one touch in 60 s is the expected result: one focus tap, no caret
repositioning, and every keystroke thereafter delivered to
`UIRemoteKeyboardWindow`. The blind spot documented at
`LastTouchTracker.swift:11-14` and `TouchOverlayWindow.swift:9-16` is real and
intentional.

## 2. An accepted inline prediction is **not** detectable in-app

The premise — "ghost text renders inside the text view, so accepting it is an
in-app touch" — is false. On iPhone the inline prediction is **accepted by
tapping the space bar**, not by touching the ghost text. That touch lands on the
system keyboard, i.e. `UIRemoteKeyboardWindow`, exactly like a QuickType bar tap.
So both members of the ambiguous pair are invisible to `TouchOverlayWindow`, and
touch data can never separate them.

Supporting negative evidence: `Tran_test2` produced substitutions labelled
`inline_prediction` yet contains **zero** touches beyond the focus tap. Had any
acceptance been an in-app tap, a second sample would exist.

Also checked: `UITextInputTraits` exposes `inlinePredictionType` to *set* the
feature (`LoggingTextView.makeUIView` leaves it at `.default`, so predictions
were live in these sessions) but exposes **nothing to read pending prediction
state**, and `UITextViewDelegate` has no acceptance callback. There is no API
route either.

## 3. New: `marked_text_before` is not dead code, it is just off by one row

Confirmed finding 2 — 0 on all 19 substitutions across both sessions. But the
column **does** fire, on 21 plain `insert` rows (6 in test1, 15 in test2), always
while a word is being typed, and always back to 0 by the time the substitution's
`shouldChangeTextIn` runs. It is a *word-level* "a candidate was pending" signal,
not a per-substitution one. It does not separate the labels either: of the three
ground-truth bar taps, only `prett`→`pretty` had `marked=1` on the preceding row.

## 4. The real result: the **trailing** delimiter gap is cleanly bimodal

Every substitution is followed by a delimiter `insert` row. Its
`inter_key_interval_ms` — a machine-generated interval, not human timing —
splits the 19 substitutions with a wide empty band and no points inside it:

| Gap | Substitutions |
|---|---|
| **4.3 – 6.6 ms** | `wrnt`→`went` 4.34, `I ask`→`i asked` 5.58, `read`→`reading` 5.59, `my dgo`→`my dog` 6.00, `coler`→`cooler` 6.58 |
| *(empty 6.6 – 11.8)* | — |
| **11.8 – 15.0 ms** | `i`→`I` ×5 (11.76–15.00), `its`→`it's` ×2, `ithacas`→`Ithaca's`, `Lol`→`lol`, **`act`→`actually` 12.68 ★**, **`prett`→`pretty` 12.35 ★**, **`wea`→`weather` 12.66 ★**, `taro`→`tarot` 14.06, `shit`→`shitt` 14.88 |

★ = the three screen-recording-confirmed bar taps. **All three land in the high
group; all three unambiguous misspelling autocorrects land in the low group.**

Restricted to the ambiguous residue (`sentence_caps` and `smart_punct` are
already certain by their own rules), the split is
{4.34, 5.58, 5.59, 6.00, 6.58} vs {12.35, 12.66, 12.68, 14.06, 14.88}.

Why this beats the ~350 ms preceding-interval fallback: 350 ms is a threshold
fitted to human reaction time on n=3, whereas the trailing gap is iOS's own
internal latency between committing a replacement and committing the following
delimiter — two different code paths inside UIKit, ~5 ms and ~13 ms. It also
disagrees with the 350 ms rule on real rows, so they are not interchangeable:
`read`→`reading` has a *preceding* gap of 386 ms (→ bar tap under the 350 ms
rule) but a *trailing* gap of 5.59 ms (→ autocorrect side). `shit`→`shitt` and
`taro`→`tarot` move to the bar-tap side, which matches the suspicion recorded in
the 2026-08-12 entry that `shitt` "is almost certainly a bar tap".

**Not shipped.** Three ground-truth labels is still three, and the causal story
(why capitalisation and smart punctuation sit with the bar taps at ~13 ms rather
than with the space-triggered autocorrects at ~5 ms) is not nailed down. This
needs the deliberate labelled trial already listed as Next step 1.

## Next

1. Run the labelled trial (`teh `+space, `tomo`+space on ghost text,
   `tomo`+bar tap, double-tap select and overtype) and check the **trailing**
   delimiter gap on each of the four, not `marked_text_before`.
2. If it holds, replace both the dead `quicktype_pick` rule
   (`substitution_metrics.py:172-175`, can never fire — finding 1) and the
   completion-vs-correction prefix fallback with the trailing-gap rule, and
   emit `next_delimiter_gap_ms` as a column so the evidence ships with the data.
3. Do **not** pursue in-app touch detection for this. It is closed.
