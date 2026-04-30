"""
Identify Power BI datasets and dataflows at risk when regular users are
removed from gateway / cloud connection access.

For each dataset, calls Get Datasources As Admin to check whether it uses a
gateway connection, then flags items where the configuredBy owner is NOT one
of the designated service accounts.

Authentication uses AzureCliCredential (az login).
The signed-in identity must have Power BI admin permissions
(Fabric Administrator or Power BI Administrator role).
"""

import csv
import os
import sys
import time
from typing import Any

from azure.identity import AzureCliCredential
from dotenv import load_dotenv
import requests

# ── Configuration ────────────────────────────────────────────────────────────

PBI_SCOPE = "https://analysis.windows.net/powerbi/api/.default"
BASE_URL = "https://api.powerbi.com/v1.0/myorg/admin"

ALL_OWNERS_FILE = "pbi_owners.csv"
AT_RISK_FILE = "pbi_at_risk.csv"


# ── Authentication ───────────────────────────────────────────────────────────

def get_access_token() -> str:
    """Acquire an access token using the Azure CLI logged-in user."""
    credential = AzureCliCredential()
    token = credential.get_token(PBI_SCOPE)
    return token.token


# ── API helpers ──────────────────────────────────────────────────────────────

def _get_all_pages(url: str, headers: dict) -> list[dict[str, Any]]:
    """Follow @odata.nextLink pagination and return all entities."""
    items: list[dict[str, Any]] = []
    while url:
        resp = requests.get(url, headers=headers, timeout=60)
        resp.raise_for_status()
        data = resp.json()
        items.extend(data.get("value", []))
        url = data.get("@odata.nextLink")
    return items


def get_datasets(headers: dict) -> list[dict[str, Any]]:
    """GET /admin/datasets — returns all datasets in the tenant."""
    return _get_all_pages(f"{BASE_URL}/datasets", headers)


def get_dataflows(headers: dict) -> list[dict[str, Any]]:
    """GET /admin/dataflows — returns all dataflows in the tenant."""
    return _get_all_pages(f"{BASE_URL}/dataflows", headers)


def get_datasources_for_dataset(
    dataset_id: str, headers: dict
) -> list[dict[str, Any]]:
    """GET /admin/datasets/{id}/datasources — datasources bound to a dataset."""
    url = f"{BASE_URL}/datasets/{dataset_id}/datasources"
    resp = requests.get(url, headers=headers, timeout=60)
    if resp.status_code == 404:
        return []
    # Handle rate-limiting (HTTP 429)
    if resp.status_code == 429:
        retry_after = int(resp.headers.get("Retry-After", "30"))
        print(f"  ⏳ Rate-limited, waiting {retry_after}s …")
        time.sleep(retry_after)
        return get_datasources_for_dataset(dataset_id, headers)
    resp.raise_for_status()
    return resp.json().get("value", [])


def uses_gateway(datasources: list[dict[str, Any]]) -> tuple[bool, str]:
    """Return (True, gateway_id) if any datasource is bound to a gateway."""
    for ds in datasources:
        gw_id = ds.get("gatewayId")
        if gw_id and gw_id != "00000000-0000-0000-0000-000000000000":
            return True, gw_id
    return False, ""


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    load_dotenv()

    raw = os.environ.get("PBI_SERVICE_ACCOUNTS", "")
    if not raw.strip():
        print(
            "Set PBI_SERVICE_ACCOUNTS in your .env file (comma-separated UPNs).\n"
            "Example:  PBI_SERVICE_ACCOUNTS=svc1@contoso.com,svc2@contoso.com",
            file=sys.stderr,
        )
        sys.exit(1)

    safe_accounts = {a.strip().lower() for a in raw.split(",") if a.strip()}

    print(f"Service accounts (safe): {', '.join(sorted(safe_accounts))}\n")

    token = get_access_token()
    headers = {"Authorization": f"Bearer {token}"}

    # ── Fetch datasets ───────────────────────────────────────────────────
    print("Fetching datasets …")
    datasets = get_datasets(headers)
    print(f"  → {len(datasets)} dataset(s) found")

    print("Checking datasources per dataset (this may take a while) …")
    all_rows: list[dict[str, str]] = []
    at_risk_rows: list[dict[str, str]] = []

    for i, ds in enumerate(datasets, 1):
        dataset_id = ds.get("id", "")
        name = ds.get("name", "")
        owner = ds.get("configuredBy", "")
        workspace = ds.get("workspaceId", "")

        datasources = get_datasources_for_dataset(dataset_id, headers)
        on_gateway, gateway_id = uses_gateway(datasources)

        ds_types = sorted(
            {src.get("datasourceType", "Unknown") for src in datasources}
        ) if datasources else []

        row = {
            "Type": "Dataset",
            "WorkspaceId": workspace,
            "Id": dataset_id,
            "Name": name,
            "ConfiguredBy": owner,
            "CreatedDate": ds.get("createdDate", ""),
            "LastRefreshTime": ds.get("lastRefreshTime", ""),
            "UsesGateway": str(on_gateway),
            "GatewayId": gateway_id,
            "DatasourceTypes": "; ".join(ds_types),
            "AtRisk": "",
        }

        is_at_risk = on_gateway and owner.strip().lower() not in safe_accounts
        row["AtRisk"] = str(is_at_risk)
        all_rows.append(row)

        if is_at_risk:
            at_risk_rows.append(row)

        if i % 10 == 0 or i == len(datasets):
            print(f"  … {i}/{len(datasets)} datasets checked", end="\r")

    print()

    # ── Fetch dataflows ──────────────────────────────────────────────────
    print("Fetching dataflows …")
    dataflows = get_dataflows(headers)
    print(f"  → {len(dataflows)} dataflow(s) found")

    for df in dataflows:
        owner = df.get("configuredBy", "")
        row = {
            "Type": "Dataflow",
            "WorkspaceId": df.get("workspaceId", ""),
            "Id": df.get("objectId", ""),
            "Name": df.get("name", ""),
            "ConfiguredBy": owner,
            "CreatedDate": df.get("modelCreatedDate", ""),
            "LastRefreshTime": df.get("modifiedDateTime", ""),
            "UsesGateway": "N/A",
            "GatewayId": "",
            "DatasourceTypes": "",
            "AtRisk": str(owner.strip().lower() not in safe_accounts),
        }
        all_rows.append(row)
        if owner.strip().lower() not in safe_accounts:
            at_risk_rows.append(row)

    # ── Write CSVs ───────────────────────────────────────────────────────
    fieldnames = [
        "Type", "WorkspaceId", "Id", "Name", "ConfiguredBy",
        "CreatedDate", "LastRefreshTime",
        "UsesGateway", "GatewayId", "DatasourceTypes", "AtRisk",
    ]

    with open(ALL_OWNERS_FILE, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(all_rows)

    with open(AT_RISK_FILE, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(at_risk_rows)

    # ── Summary ──────────────────────────────────────────────────────────
    print(f"\nAll items  → {ALL_OWNERS_FILE}  ({len(all_rows)} rows)")
    print(f"At-risk    → {AT_RISK_FILE}  ({len(at_risk_rows)} rows)")

    if at_risk_rows:
        impacted_users = sorted({r["ConfiguredBy"] for r in at_risk_rows if r["ConfiguredBy"]})
        print(f"\n⚠  {len(at_risk_rows)} item(s) at risk, owned by {len(impacted_users)} user(s):")
        for user in impacted_users:
            user_items = [r for r in at_risk_rows if r["ConfiguredBy"] == user]
            print(f"   • {user}  ({len(user_items)} item(s))")
            for item in user_items:
                print(f"       – [{item['Type']}] {item['Name']}")
    else:
        print("\n✅  No at-risk items found. All datasets/dataflows are owned by service accounts.")


if __name__ == "__main__":
    main()

