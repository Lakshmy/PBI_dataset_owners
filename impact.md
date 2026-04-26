## What permissions are changing

On a Power BI gateway data source / cloud connection, the "Users" tab grants connection user access. That access lets someone bind a semantic model to the connection (i.e., publish a dataset and have it refresh through that connection). It is **not** what report viewers need to view a report.

We are removing all regular BlueScope users from the connection user lists, leaving only the two service accounts with access.

## What WON'T break

- **Report viewing** — Consumers of reports/apps don't need any access on the gateway connection. They only need Read on the semantic model or workspace. Untouched.
- **Existing scheduled refreshes** — Datasets owned by your two service/admin accounts will continue to refresh normally, provided those accounts remain authorised on the connection and credentials remain valid.
- **DirectQuery / Live connection reports (stored credentials)** — When the connection uses stored credentials (not SSO), queries execute through the gateway using those stored credentials. End-user permission on the connection isn't checked at query time. Untouched.
- **RLS, sensitivity labels, dataset Build/Read permissions** — All independent of gateway connection access.

## What WILL break

The risks are limited to cases where a regular user is currently the owner of a published dataset using these connections, or wants to publish/author new ones:

- **Datasets currently owned by a regular user** — Refresh will fail with "user has no access to the gateway/data source." This is the main thing to audit before you flip the switch.
- **New publishes / re-publishes by regular users** — Publish/republish may succeed, but the user will be unable to rebind the model to the connection or configure refresh. Note that republishing drops the prior gateway association, so even previously working models will need re-binding.
- **"Take over" actions** — If a regular user clicks Take over on a dataset, refresh will fail because their identity now drives refresh and they can't reach the connection. The new owner may also need to re-enter or rebind credentials.
- **Personal datasets in My Workspace** — Any that use these gateway connections will lose refresh.
- **Dataflows owned by regular users** — Same refresh issue as datasets for any dataflows using these connections.
- **Paginated reports (.rdl)** — Report viewing is unaffected, but owners/publishers of paginated reports that use these connections will lose the ability to configure credentials or binding.
- **Web authoring (Get Data in Power BI Service)** — Removed users will no longer be able to create new semantic models, dataflows, or reports in the Service against these governed connections.
- **DirectQuery / Live connection with SSO** — If any connections use SSO (Kerberos or Entra SSO), runtime queries may be evaluated under the viewer's identity at the data source. While viewers don't need connection user access, source-side authorisation may still affect query results. Audit which connections use SSO to understand this impact.
- **Composite models / chained semantic models** — Downstream models owned by regular users that bind or refresh through these connections will be affected in the same way as standard datasets.

## Recommended pre-flight steps

1. **Inventory ownership** — Use the Power BI admin REST APIs (Get Datasets As Admin, Get Dataflows As Admin) or the activity log/scanner API to list every dataset/dataflow and its `configuredBy` owner. Flag any where the owner is not one of the two service accounts.
2. **Audit paginated reports** — Identify any `.rdl` reports bound to these connections and check their owners.
3. **Identify SSO connections** — Determine which connections use SSO (Kerberos/Entra). The DirectQuery/Live impact analysis changes materially for these.
4. **Reassign ownership first** — Have the two service accounts "Take over" those datasets/dataflows so refresh moves to a permitted identity before you remove regular-user access. Validate gateway/connection binding after takeover, not just ownership.
5. **Pilot the change** — Remove regular-user access on a subset of connections/workspaces first and monitor refresh/query failures for a few days before rolling out tenant-wide.
6. **Use a security group** for the two service accounts on each connection's Users list, so future rotation is easier.
7. **Communicate the new pattern** — Going forward, regular users build and publish, but ownership of any refreshing dataset is handed to the service account. They keep workspace Contributor/Member and Build permission on shared semantic models — that's all they need to author. Document the workflow: publish → service account takeover → validate refresh.
8. **Watch out for personal gateway connections and My Workspace datasets** — these often slip through governance reviews.