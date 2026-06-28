# decisions/ — Design & Research Decision Records

Short ADR-style notes capturing *why* a choice was made — threshold values, model
parameters, study-design tradeoffs — so future agents don't re-litigate settled
questions. These rationales tend to vanish from commit messages and code comments.

One file per decision: `NNNN-short-slug.md` (zero-padded sequence). Template:

```markdown
# NNNN — <decision>
- **Status:** accepted | superseded by NNNN | proposed
- **Date:** YYYY-MM-DD
- **Context:** what problem / question prompted this.
- **Decision:** what was chosen.
- **Rationale:** why, including data/citations.
- **Consequences:** what this enables or constrains; alternatives rejected.
```

> Note: decisions below were reconstructed from code/comments by an agent. Confirm
> the rationale with the project owner and mark `Status: accepted` once verified.
