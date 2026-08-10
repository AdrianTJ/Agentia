# Retrieval Evaluation — Run 41

Generated 14:22:07 · this document exists to break the renderer, not to read well.

This run swapped the reranker from `bge-reranker-base` to `bge-reranker-v2-m3` and widened
the candidate pool from 20 to 50 documents. Recall improved materially; latency did not
degrade as much as the pilot suggested.

> The reranker change is safe to promote. The candidate-pool widening is not — it pushes p99
> past the 800 ms budget on the cold-cache path.

## A wide table that must not widen the page

| Metric | Run 38 | Run 39 | Run 40 | Run 41 | Δ vs 40 | Budget | Status | Owner |
| ------ | -----: | -----: | -----: | -----: | ------: | -----: | :----: | ----- |
| Recall@10 | 0.681 | 0.694 | 0.712 | 0.849 | +19.2% | 0.800 | pass | retrieval |
| MRR | 0.577 | 0.588 | 0.601 | 0.688 | +14.5% | 0.650 | pass | retrieval |
| p50 latency | 171 ms | 178 ms | 184 ms | 203 ms | +10.3% | 250 ms | pass | serving |
| p99 latency | 588 ms | 596 ms | 602 ms | 871 ms | +44.7% | 800 ms | fail | serving |
| Index size | 4.1 GB | 4.2 GB | 4.2 GB | 4.9 GB | +16.7% | 6.0 GB | pass | infra |

## A code block with lines far wider than the measure

```python
def evaluate(index_snapshot: str, reranker: str, pool_width: int, seed: int, *, emit_markdown: bool = True, emit_html: bool = True) -> EvaluationReport:
    """One very long signature plus a long comment line, both of which must wrap on paper rather than being silently clipped at the right edge of the sheet."""
    candidates = retrieve(index_snapshot, pool_width=pool_width, seed=seed, filters={"effective_date": {"$gte": "2026-01-01"}, "language": "en"})
    reranked = rerank(candidates, model=reranker, batch_size=32, normalize=True, truncate_tokens=512)
    return EvaluationReport(recall_at_10=recall(reranked, k=10), mrr=mean_reciprocal_rank(reranked), latency_p99=percentile(latencies, 99))
```

## Deep nesting

1. Table fragmentation — 61% of remaining misses
   - The chunker splits tables mid-row
     - So the embedding never sees a complete record
       - Which means recall is bounded by chunk boundaries, not by the model
         - And no reranker change can fix it
2. Acronym collisions — 22%
   - Needs a domain glossary at query-expansion time
3. Temporal drift — 17%

## Task list

- [x] Swap the reranker
- [x] Re-run the sweep at pool width 50
- [ ] Fix the chunker so tables stay intact
- [ ] Re-measure p99 after the chunker fix
- [ ] Add effective-date metadata to the index

## Long unbroken tokens

A bare URL that cannot be hyphenated: https://internal.example.com/evaluation/runs/41/artifacts/retrieval-report-2026-08-07T14-22-07Z-seed41-pool50-reranker-bge-v2-m3.json

An identifier of the kind agents emit: `sha256:9f2c4a1be77d0e3ab58c6f01d4e9a2b83c7f6019de45a8b2c130f7e6a95d8c4b`

## Raw HTML in Markdown

<details>
<summary>Collapsed detail block</summary>

Agent Markdown uses this constantly, so it has to survive the parser.

</details>

<div style="padding:8px;border:1px solid #ccc;border-radius:6px;">
An inline-styled block. Styles are allowed; scripts are not.
</div>

## Things that must never execute

<script>window.__agentiaScriptRan = true;</script>

<img src="x" onerror="window.__agentiaOnErrorRan = true;" alt="broken image with an onerror handler">

<a href="javascript:window.__agentiaJavascriptURLRan=true">a javascript: link</a>

## Typography and unicode

Ligatures: office, difficult, affluent. Quotes: "curly" and 'single'. Dashes: en – em —.
Maths: 1 ≤ x ≤ 10, α β γ, ∑, ≈, ±. CJK: 検索評価. Emoji: ✅ ⚠️ 🚀. RTL: العربية.

Footnote reference[^method] and a second one[^data].

[^method]: The harness is deterministic given a fixed seed and a pinned index snapshot.
[^data]: Pro Git corpus, 11 MB, 181 files.

---

## Final section

Ship the reranker. Hold the pool width at 20 until the chunker fix lands, then re-measure —
the p99 regression is almost certainly an artifact of fragmented tables inflating the
candidate set with near-duplicates.
