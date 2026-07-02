# PBI Dataset Owners

This repository contains two complementary tools:

- **Part 1 — Gateway Access Impact Audit** ([`pbi_dataset_owners.py`](python_scripts/pbi_dataset_owners.py)): a local Python script that flags datasets/dataflows at risk when users lose gateway access.
- **Part 2 — Tenant-Wide Dataset Refresh Audit** ([`dataset_audit.ipynb`](python_scripts/dataset_audit.ipynb)): a Fabric notebook that reports the refresh configuration of every dataset in the tenant.

---

# Part 1 — Gateway Access Impact Audit

Identify Power BI **datasets** and **dataflows** at risk when regular users are removed from gateway / cloud connection access.

For each dataset the script calls the [Power BI Admin REST APIs](https://learn.microsoft.com/rest/api/power-bi/admin) to:
- List every dataset and dataflow with its `configuredBy` owner.
- Check whether the dataset uses a **gateway connection** (via Get Datasources As Admin).
- Flag items as **at risk** where the owner is not one of the designated service accounts.

## Prerequisites

| Requirement | Details |
|---|---|
| Python | 3.10+ |
| Identity | Signed-in user with **Fabric Administrator** or **Power BI Administrator** role |
| Azure CLI | `az login` — the script authenticates via `AzureCliCredential` |

## Setup

```bash
pip install -r requirements.txt
```

Ensure you're logged in with a user that has Power BI admin permissions:

```bash
az login
```

Create a `.env` file (or edit the included one) with the service accounts that will **keep** gateway connection access:

```env
PBI_SERVICE_ACCOUNTS=svc1@contoso.com,svc2@contoso.com
```

## Usage

```bash
python pbi_dataset_owners.py
```

## Output

The script produces:

| File | Description |
|---|---|
| `pbi_owners.csv` | All datasets and dataflows in the tenant |
| `pbi_at_risk.csv` | Only items owned by non-service-account users that use a gateway connection |

Both CSVs contain the columns: `Type`, `WorkspaceId`, `Id`, `Name`, `ConfiguredBy`, `UsesGateway`, `GatewayId`, `DatasourceTypes`, `AtRisk`.

A summary of impacted users and their at-risk items is also printed to the console.

---

# Part 2 — Tenant-Wide Dataset Refresh Audit (Fabric Notebook)

The [`dataset_audit.ipynb`](python_scripts/dataset_audit.ipynb) notebook scans **every workspace** in your Microsoft Fabric tenant and reports the **refresh configuration** of each dataset (semantic model). It answers questions like *"Which datasets are Import vs. DirectQuery?"*, *"Which have a scheduled refresh?"*, and *"Who owns them?"*.

Unlike Part 1 (a local Python script), this notebook is designed to run **directly inside a Microsoft Fabric notebook**, using the notebook's own identity — so no secrets are required.

## What it does

The notebook calls the [Power BI Admin REST APIs](https://learn.microsoft.com/rest/api/power-bi/admin) to:

1. **List all workspaces** in the tenant (via `GET /admin/groups`, paginated).
2. **List all datasets** across the tenant (via `GET /admin/datasets`, paginated).
3. **Enrich each dataset** with its detailed configuration (via `GET /admin/datasets/{id}`), using a thread pool for speed.
4. **Classify the refresh type** of each dataset:

   | Refresh Type | Meaning | Storage Mode |
   |---|---|---|
   | Full Refresh | Complete data reload each cycle | Import |
   | Incremental Refresh | Only new/changed data loaded | Import |
   | DirectQuery (No Refresh) | Live connection | DirectQuery |
   | No Schedule | Configured but not scheduled | Import |
   | Not Configured | No refresh settings | Unknown |

5. **Build a results table** (pandas DataFrame) with one row per dataset, including workspace name, dataset name, refresh type, schedule status, scheduled times, default mode, and owner.
6. **Print summary statistics** — total datasets/workspaces and the distribution of refresh types and storage modes.
7. **Optionally persist** the results to an attached Lakehouse as a Delta table (`dataset_refresh_audit`).

## Prerequisites

| Requirement | Details |
|---|---|
| Environment | A **Microsoft Fabric** workspace with notebook support |
| Identity | Run the notebook as a user with the **Fabric Administrator** / **Power BI Administrator** role (or a service principal with Admin API `Tenant.Read.All` access) |
| Lakehouse | *Optional* — attach a Lakehouse only if you want to save results as a Delta table |

## How to run

1. **Import the notebook** into your Fabric workspace (Workspace → New → Import notebook → upload [`dataset_audit.ipynb`](python_scripts/dataset_audit.ipynb)).
2. *(Optional)* **Attach a Lakehouse** if you plan to save the results as a Delta table.
3. **Set the parameters** in the *Parameters* cell (cell 0). The defaults work for most interactive runs:

   ```python
   auth_method = "fabric_integrated"   # uses the notebook's own identity (default)
   tenant_id = ""                       # only for auth_method = 'service_principal'
   client_id = ""
   client_secret = ""
   max_workers = 5                      # parallel workers for dataset enrichment
   save_to_lakehouse = True             # set False to skip the Delta table write
   lakehouse_table_name = "dataset_refresh_audit"
   ```

4. **Run all cells** top to bottom. The notebook will:
   - authenticate,
   - scan the tenant,
   - display the full results table, and
   - (optionally) write the Delta table to the attached Lakehouse.

### Authentication options

The `auth_method` parameter controls how the notebook authenticates:

| `auth_method` | When to use | Requires |
|---|---|---|
| `fabric_integrated` *(default)* | Interactive runs inside Fabric | Nothing — uses `notebookutils` notebook identity |
| `service_principal` | Automated / scheduled jobs | `tenant_id`, `client_id`, `client_secret` (parameters or `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` env vars) |
| `default_azure` | CLI / managed identity contexts | A valid `DefaultAzureCredential` chain |

## Output

| Output | Description |
|---|---|
| In-notebook table | Full results DataFrame, sorted by workspace and dataset name |
| Console summary | Total datasets/workspaces plus refresh-type and default-mode distributions |
| Lakehouse Delta table | *(optional)* `dataset_refresh_audit` — includes an `Audit_Timestamp` column and sanitized column names |

The results table contains the columns: `Workspace Name`, `Workspace ID`, `Dataset Name`, `Dataset ID`, `Refresh Type`, `Is Incremental`, `Schedule Enabled`, `Scheduled Times`, `Default Mode`, `Owner`, and `Target Storage Mode`.

> **Note:** To schedule this notebook, run it from a Fabric pipeline or scheduled job and override the *Parameters* cell — using `auth_method = "service_principal"` for non-interactive authentication.