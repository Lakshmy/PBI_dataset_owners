# PBI Dataset Owners

List every Power BI **dataset** and **dataflow** in your tenant along with the `configuredBy` owner, using the [Power BI Admin REST APIs](https://learn.microsoft.com/rest/api/power-bi/admin).

## Prerequisites

| Requirement | Details |
|---|---|
| Python | 3.10+ |
| Identity | Signed-in user with **Fabric Administrator** or **Power BI Administrator** role |
| Azure CLI | `az login` (or any credential source supported by `DefaultAzureCredential`) |

## Setup

```bash
pip install -r requirements.txt
```

Ensure you're logged in with a user that has Power BI admin permissions:

```bash
az login
```

## Usage

```bash
python pbi_dataset_owners.py
```

The script will:
1. Authenticate via client-credentials (MSAL).
2. Call **GET /admin/datasets** and **GET /admin/dataflows** (with pagination).
3. Print a summary table to stdout.
4. Write a CSV file (`pbi_owners.csv`) with columns: `Type, WorkspaceId, Id, Name, ConfiguredBy`.