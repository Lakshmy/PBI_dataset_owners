# Semantic Model Incremental Refresh Audit

`semantic_model_incremental_refresh_audit.ipynb` performs a **tenant-wide audit** of Power BI / Fabric semantic models to determine **which models have incremental refresh configured and which do not**.

## What it does

- Lists every workspace (`/admin/groups`) and semantic model (`/admin/datasets`) in the tenant using the **Power BI Admin API**.
- Connects to each capacity-backed model **read-only over the XMLA endpoint** (via `semantic-link-labs` / TOM) and inspects every table's `RefreshPolicy`.
- A non-null `RefreshPolicy` means incremental refresh is configured; the notebook captures the **store (archive) window** and the **refresh window** for each incremental table.
- Produces a results DataFrame and (optionally) writes it to an attached Lakehouse as a Delta table.

### Why XMLA?
Incremental refresh is a **table-level refresh policy** driven by the reserved `RangeStart` / `RangeEnd` Power Query parameters. The service manages the partitions, and the policy is only exposed through the **XMLA endpoint** — no Power BI REST API returns it.

## Prerequisites

- **Environment:** A Microsoft Fabric notebook (or any environment with XMLA connectivity to Power BI).
- **Permissions:** The identity needs **Fabric / Power BI Admin** rights to list all datasets, plus access to each workspace to read its model.
- **Capacity:** Models must be on a capacity exposing the **XMLA read endpoint** — **Premium / PPU / Fabric**. Models on shared **Pro** capacity have no XMLA endpoint and are reported as `Unknown`.
- **Package:** `semantic-link-labs` (`sempy_labs`) — installed by the first cell of the notebook.
- **Scope:** Semantic models only. **Dataflows are not covered.**

## How to run

1. Open the notebook in a Fabric notebook (recommended) or an environment with XMLA access.
2. **Run cell 1 (Install dependencies)** once per session. If the import check fails, **restart the kernel** and re-run from the top.
3. **Set the parameters cell** (tagged `parameters` so it can be overridden by a pipeline/scheduled job):
   - `auth_method` — `fabric_integrated` (default, uses notebook identity), `service_principal`, or `default_azure`.
   - `tenant_id`, `client_id`, `client_secret` — only required when `auth_method = 'service_principal'`.
   - `max_workers` — number of parallel XMLA connections (keep low, e.g. 4, to avoid overloading endpoints).
   - `skip_non_capacity_workspaces` — `True` skips Pro workspaces (no XMLA endpoint).
   - `workspace_ids_filter` — list of workspace IDs to restrict the scan (empty = whole tenant).
   - `save_to_lakehouse` / `lakehouse_table_name` — optional Delta output to an attached Lakehouse.
4. **Run all remaining cells.** The audit lists workspaces/datasets, probes each capacity-backed model over XMLA, and builds the results table.
5. Use the **explore cells** (section 8) to filter results, or enable **section 9** to save to a Lakehouse.

## How to interpret the results

The results DataFrame contains one row per semantic model with these key columns:

| Column | Meaning |
|---|---|
| `Workspace Name` / `Workspace ID` | Workspace hosting the model |
| `On Dedicated Capacity` | Whether the workspace is on Premium/PPU/Fabric capacity |
| `Dataset Name` / `Dataset ID` | The semantic model |
| `Is Incremental` | `True` = incremental refresh configured; `False` = definitively not configured (read via XMLA); `Unknown` = could not read (see `Detection Source`) |
| `Incremental Tables` | Tables that carry a refresh policy (or `None`) |
| `Policy Details` | Per table: store window and refresh window (e.g. `Sales: store 5 Years, refresh 10 Days`) |
| `Detection Source` | `XMLA` (successfully read), `No XMLA (shared/Pro capacity)`, or `Unavailable (sempy_labs not installed)` |
| `Is Refreshable` | Admin API refreshable flag |
| `Target Storage Mode` | Import / DirectQuery / etc. |
| `Owner` | `configuredBy` — model owner |
| `Error` | Any XMLA read error encountered |

### Reading the outcome

- **`Is Incremental = True`** — the model uses incremental refresh; check `Incremental Tables` and `Policy Details` for the configured windows.
- **`Is Incremental = False`** — confirmed (via XMLA) that no table has a refresh policy.
- **`Is Incremental = Unknown`** — the model could not be read. Common reasons shown in `Detection Source`:
  - `No XMLA (shared/Pro capacity)` — the model is on Pro capacity with no XMLA endpoint. This is expected, not an error.
  - An XMLA error (see the `Error` column) — e.g. insufficient permissions or the endpoint was unavailable.

The run also prints summary counts: total models, distribution of `Is Incremental`, distribution of `Detection Source`, and totals of models with vs. without incremental refresh.
