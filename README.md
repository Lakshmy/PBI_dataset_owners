# PBI Dataset Owners

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