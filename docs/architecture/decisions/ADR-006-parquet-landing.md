# ADR-006: Parquet (Snappy) as landing format

**Status:** Accepted

## Context
Need typed, compressed, splittable files; CSV caused delimiter/encoding defects in the PoC (claim notes with pipes and newlines).

## Decision
Parquet with Snappy, 128–256 MB files, one folder per run.

## Alternatives considered
CSV/gzip (rejected: type loss, delimiter issues); Avro (row-based, fine but less compression for analytics); Delta (not needed; Snowflake is the table format owner).

## Consequences
SHIR CPU for Parquet encoding (scaled out); DECIMAL precision must be preserved end to end (verified by recon type checks).
