# Project 32 — VM Scale Set with CPU-Based Autoscaling

An Azure Virtual Machine Scale Set that runs a small nginx web app behind a load balancer and grows or shrinks itself based on CPU load. Every VM installs the application on itself at boot by pulling the files from a **private** blob container, authenticated with a **managed identity** — no SSH, no keys, no manual steps. All infrastructure is defined as modular Bicep.

---

## What it does

Two VMs serve a web page through a single public IP. When average CPU across the scale set stays above 70% for five minutes, Azure adds a VM. That new VM boots, downloads the app from blob storage using its managed identity, installs nginx, and joins the load balancer pool — with nobody logged into it. When CPU drops below 30% for ten minutes, Azure removes a VM again, down to a floor of two.

The page itself reports which VM served it and when that VM was provisioned, which makes both the load balancing and the autoscaling visible in a browser.

---

## Architecture

```
Internet ──► Public IP ──► Standard Load Balancer ──► Backend Pool
                              │ (HTTP probe :80)          │
                              │                    ┌──────┴────────┐
                              │                    │  VMSS         │
                              │                    │  vm_0  vm_1 … │ ◄── Autoscale (Percentage CPU)
                              │                    └──────┬────────┘
                              │                           │ user-assigned managed identity
                              └── outbound rule ◄─────────┼──► apt repositories
                                                          └──► Storage Account (private blob)

            VNet 10.0.0.0/16 → subnet 10.0.1.0/24, NSG allows inbound TCP 80 only
```

The VMs have **no public IP addresses**. Inbound traffic arrives only through the load balancer; outbound traffic leaves through the load balancer's outbound rule. Administration is done with `az vmss run-command`, so port 22 is never exposed to the internet.

---

## Tech stack

| Component | Service / tool | Why |
|---|---|---|
| Infrastructure as code | Bicep (modular) + `.bicepparam` | One template per concern, environment values separated from logic |
| Deployment | Azure CLI (`az deployment group create`) | — |
| Network | VNet, subnet, NSG | Private address space; NSG allows only inbound TCP 80 |
| Entry point | Standard Load Balancer + Standard Public IP | Single public address, health-checked traffic distribution, outbound internet for the VMs |
| App artifacts | Storage Account, private blob container | Realistic artifact store; public blob access disabled, HTTPS only, TLS 1.2 minimum |
| Access control | User-assigned managed identity + `Storage Blob Data Reader` | VMs read the blob with no key, password, or SAS token |
| Compute | VMSS (Uniform), Ubuntu 22.04 LTS, `Standard_B1s` | Identical, disposable instances; smallest size to keep cost low |
| Configuration | Custom Script Extension (JSON `fileUris` + `commandToExecute`) | Every VM configures itself at boot, including ones autoscale creates later |
| Web server | nginx | Serves the sample page on port 80 |
| Scaling | Azure Monitor autoscale settings | CPU-driven scale out and in |

---

## Repository layout

```
Project-32-VMSS/
├── infra/
│   ├── main.bicep              orchestrator — calls every module
│   ├── main.bicepparam         environment values
│   └── modules/
│       ├── network.bicep       VNet, subnet, NSG
│       ├── loadBalancer.bicep  public IP, LB, probe, LB rule, outbound rule
│       ├── storage.bicep       storage account, blob service, container
│       ├── identity.bicep      user-assigned identity + role assignment
│       ├── vmss.bicep          scale set + Custom Script Extension
│       └── autoscale.bicep     autoscale profile and rules
├── app/
│   └── index.html              the sample page (with placeholder tokens)
└── README.md
```

---

## Design decisions

**Why a user-assigned managed identity rather than system-assigned.** The Custom Script Extension needs permission to read the blob *while the scale set is being created*. A system-assigned identity does not exist until the VMSS exists, so the role assignment could not be granted in time. A user-assigned identity is a standalone resource: it is created first, granted `Storage Blob Data Reader` scoped to the single storage account, and then handed to the scale set.

**Why the role is scoped to the storage account.** Role assignments inherit downward. Scoping at the subscription or resource group would let the identity read blobs far beyond this project. The narrowest scope that does the job limits the damage if the identity is ever compromised.

**Why the load balancer needs an explicit outbound rule.** A Standard Load Balancer gives VMs no route to the internet by default. Without the rule, `apt-get install nginx` would hang and the extension would fail with a timeout that gives no hint of the real cause. `allocatedOutboundPorts` is pinned at 8000 so that autoscale events do not force Azure to reallocate SNAT ports across instances and drop connections in flight.

**Why deployment happens in two stages.** The scale set tries to download `index.html` the moment it is created, so the blob must already exist. A `deployVmss` boolean parameter gates the VMSS and autoscale modules with `if (deployVmss)`. Stage one deploys the foundation with the flag false; the blob is uploaded; stage two sets the flag true. The same pattern is commonly used to vary a single template across environments.

**Why scale-out and scale-in are asymmetric.** Scale out looks back over five minutes; scale in looks back over ten. Being under-provisioned costs customers, while being over-provisioned costs pennies, so the system is deliberately eager to add capacity and reluctant to remove it.

---

## Deploying

### Prerequisites

- Azure CLI and Bicep (`az bicep version`)
- An SSH public key; the path is set in `main.bicepparam`
- Permission to create role assignments in the subscription

### Stage 1 — foundation

Set `deployVmss = false` in `infra/main.bicepparam`, then:

```bash
az group create --name rg-prj32-vmss --location uksouth --tags project=project32-VMSS createdby=ais
```

```bash
az deployment group create --resource-group rg-prj32-vmss --name stage1-foundation --parameters infra/main.bicepparam
```

Note the `storageAccountName` from the deployment outputs.

### Stage 1b — grant yourself blob data access

Being Owner of the subscription allows you to manage the storage account but **not** to read or write its contents — those are separate data-plane roles. Grant yourself the data role, using your object ID rather than your email (guest accounts have mangled UPNs):

```bash
az ad signed-in-user show --query id -o tsv
```

```bash
az role assignment create --assignee <object-id> --role "Storage Blob Data Contributor" --scope <storage-account-resource-id>
```

Role assignments take a few minutes to propagate.

### Stage 1c — upload the app

```bash
az storage blob upload --account-name <storageAccountName> --container-name webapp --name index.html --file app/index.html --auth-mode login --overwrite
```

### Stage 2 — scale set and autoscale

```bash
az deployment group create --resource-group rg-prj32-vmss --name stage2-vmss --parameters infra/main.bicepparam --parameters deployVmss=true
```

### Verify

```bash
az vmss list-instances -g rg-prj32-vmss -n prj32-vmss -o table
```

```bash
az network public-ip show -g rg-prj32-vmss -n prj32-publicIP --query ipAddress -o tsv
```

Request the page several times — the hostname should alternate between instances. A browser will reuse one connection and tend to stick to a single VM, so use `curl` to see the rotation.

---

## The Custom Script Extension

`fileUris` points at the blob and lives in plain `settings`; the managed identity reference and the install command live in encrypted `protectedSettings`.

```
cloud-init status --wait
  && apt-get update
  && apt-get install -y nginx
  && cp index.html /var/www/html/index.html
  && chmod 644 /var/www/html/index.html
  && sed -i "s|__HOSTNAME__|$(hostname)|g" /var/www/html/index.html
  && sed -i "s|__TIMESTAMP__|$(date)|g" /var/www/html/index.html
  && systemctl enable nginx
  && systemctl restart nginx
```

Each step is chained with `&&` so that a failure stops the chain instead of continuing silently. The two `sed` commands replace placeholder tokens in the HTML with the VM's own hostname and the time it was provisioned.

---

## Autoscale configuration

| Setting | Scale out | Scale in |
|---|---|---|
| Metric | `Percentage CPU` (average across instances) | `Percentage CPU` |
| Condition | Greater than 70% | Less than 30% |
| Look-back window | 5 minutes | 10 minutes |
| Action | +1 instance | −1 instance |
| Cooldown | 5 minutes | 10 minutes |
| Capacity | minimum 2, maximum 4, default 2 | |

Because the metric is averaged across every instance, a load test must load **all** instances — loading one VM out of two produces a 50% average, which never crosses the threshold.

---

## Testing the autoscale

Generate CPU load on each instance without opening SSH:

```bash
az vmss run-command invoke -g rg-prj32-vmss -n prj32-vmss --instance-id 0 --command-id RunShellScript --scripts "setsid nohup timeout 900 yes > /dev/null 2>&1 < /dev/null & echo load-started"
```

`yes > /dev/null` burns CPU with nothing to install; `timeout 900` stops it automatically after fifteen minutes; `setsid nohup ... &` detaches it so the command returns instead of hanging.

Watch the metric rather than the instance count — it is the leading indicator:

```bash
az monitor metrics list --resource prj32-vmss --resource-group rg-prj32-vmss --resource-type Microsoft.Compute/virtualMachineScaleSets --metric "Percentage CPU" --interval PT1M --query "value[0].timeseries[0].data[-8:]" -o table
```

Stop the load with `pkill yes` through the same `run-command` mechanism.

### Observed result

Load was applied to both original instances, then released. Average CPU readings (one-minute grain) and the resulting instance count:

| Time (UTC) | Average CPU | Instances | What was happening |
|---|---|---|---|
| baseline | 0.4 – 1.8% | 2 | idle |
| 19:22 | 77.5% | 2 | threshold crossed |
| 19:23 | 61.8% | 3 | third VM added — the new instance pulls the average down |
| 19:24 | 63.1% | 3 | |
| 19:25 | 77.6% | 4 | **maximum capacity reached** |
| 19:26 | 3.9% | 4 | load released |
| 19:27 | 55.6% | 4 | residual |
| 19:28 | 13.5% | 4 | |
| 19:29 | 0.6% | 4 | below the 30% scale-in threshold |
| ~19:30 | 0.4% | 3 | first instance removed |
| ~19:40 | 0.4% | **2** | second removed — floor reached, scaling stops |

**The scale set grew from 2 to its ceiling of 4**, confirming both the scale-out rule and the `maximum` cap. All four instances served traffic — ten requests through the load balancer returned `p32vm000000`, `p32vm000001`, `p32vm000002` and `p32vm000003`, meaning the two VMs created by autoscale had installed the application on themselves and passed the health probe with nobody logged into them.

Two behaviours worth noting in that table:

- **The average fell as instances were added** (77.5% → 61.8%). Adding capacity dilutes the metric, which is exactly the self-correcting feedback loop autoscale depends on — and why the rule fired twice rather than endlessly.
- **Scale-in happened one instance at a time**, roughly ten minutes apart, because each `ChangeCount` action removes a single VM and then waits out its cooldown. It stopped at 2 and did not go lower, which is the `minimum` doing its job.

Scale-out took roughly 8–12 minutes end to end: metric ingestion lag, then the five-minute window, then VM creation and extension execution. Scale-in was deliberately slower, as designed.

---

## Problems encountered and how they were solved

These four failures were the most instructive part of the project.

### 1. Scale set refused to deploy — no primary network interface

```
VMScaleSetNetworkProfileMustHaveOnePrimaryNetworkInterfaceConfig ... has 0 primary
```

A VM may have several network interfaces, and exactly one must be marked primary — it carries the default route and is where the load balancer attaches. Azure will not guess, even when there is only one interface. Fixed by adding `primary: true` to the NIC configuration.

### 2. `E: Unable to locate package nginx` — a race with cloud-init

The extension's `apt-get update` succeeded, downloading 48 MB of package lists, and the very next command could not find nginx. Comparing the two sources revealed the cause: the update had fetched from `archive.ubuntu.com`, while the VM's `sources.list` pointed at `azure.archive.ubuntu.com`.

Azure Ubuntu images run two configuration systems at boot. cloud-init rewrites `sources.list` to Azure's local mirror, and apt files its downloaded package lists under the URL they came from. cloud-init swapped the mirror *between* the update and the install, orphaning every list that had just been downloaded — leaving apt with an effectively empty package database.

Fixed by prefixing the command with `cloud-init status --wait`, so that apt only runs once cloud-init has finished. The failure is intermittent by nature, which makes it worth knowing rather than rediscovering.

### 3. `cp: cannot stat '.../download/0/index.html'`

The Custom Script Extension downloads files into a **sequence-numbered** directory that is not always `0` — the number increments each time the extension runs on a VM. The extension also sets the working directory to that folder before running the command, so a bare relative path is both simpler and correct. Fixed by using `cp index.html ...` instead of the hardcoded absolute path.

General lesson: when a tool tells you where it put something, do not hardcode a guess at the path.

### 4. HTTP 403, a failing health probe, and a 30-second timeout

The site hung and timed out. The shape of the failure was itself a clue: a **timeout** means packets vanished, whereas **connection refused** would mean something answered and said no.

Checking from inside the VM showed nginx `active` but returning **403** on `localhost`. That single fact explained everything:

```
nginx returns 403
  → the load balancer's HTTP probe expects 200, so it fails
    → the VM is marked unhealthy and removed from rotation
      → with no healthy backends, the LB silently drops traffic
        → the client hangs for 30 seconds and times out
```

The load balancer was behaving correctly; it was protecting users from a broken VM.

The 403 came from file permissions. The extension downloads files as mode `600` owned by `root`, `cp` carried that mode across to the web root, and nginx — which drops to the unprivileged `www-data` user to serve requests — could not read the file. Fixed with `chmod 644` after the copy.

---

## Key lessons learnt

A condensed reference of everything this project taught, kept short enough to re-read before the next one.

### Bicep syntax and structure

- **`targetScope = 'resourceGroup'`**, not `:`. Top-level declarations (`param`, `var`, `output`, `targetScope`) use `=`; colons are only for keys inside an object.
- **`{ }` makes an object; `'${ }'` interpolates a string.** If a value is already the type you need, pass it bare — no braces, no interpolation.
- **`resourceId()` child types are plural and must match the property name.** `loadBalancers/backendAddressPools`, not `backendAddressPool`. The number of `/`-separated segments after the namespace must equal the number of name arguments. Bicep does not validate this; Azure rejects it at deploy time.
- **Inside a resource, you cannot reference your own child elements.** Load balancer rules need `resourceId()` with the LB name held in a `var`, used for both the resource name and every reference, so the two can never drift.
- **Paths in `loadTextContent()` resolve relative to the file they are written in**, not the working directory or the project root. The most common Bicep path mistake.
- **`@secure()` parameters cannot have a default value.** They also appear in deployment history as `"type": "SecureString"` with no value — a quick way to confirm a secret is genuinely protected.
- **Conditional modules:** `module x './y.bicep' = if (flag) { ... }`. Any output referencing them needs the non-null assertion and a fallback: `flag ? xModule!.outputs.z : ''`.
- **Reference the resource symbol, not a rebuilt string.** `uami.id` beats `resourceId(type, name)` — rename the resource and the reference follows automatically.
- **`uniqueString(resourceGroup().id)`** gives a stable, globally unique suffix: identical on redeploy, different per subscription or resource group. Deleting and recreating the same resource group reproduces the same name.
- **Compiled JSON is build output.** Keep it out of the source tree and gitignore it, or it drifts from the Bicep and confuses you later.
- **Take linter warnings seriously.** "Parameter declared but never used" caught a real bug — a feature flag that had been wired nowhere.

### Azure platform behaviour

- **A Standard Load Balancer gives VMs no outbound internet by default.** Without an explicit outbound rule, package installs hang and extensions fail with timeouts that never mention networking. Set `disableOutboundSnat: true` on the load balancing rule when an outbound rule exists, and pin `allocatedOutboundPorts` so autoscale events do not reshuffle SNAT allocations.
- **Exactly one NIC configuration must be `primary: true`**, even when there is only one.
- **Layer 4 versus Layer 7.** A load balancer rule forwards `Tcp` and never reads the HTTP inside it. The health probe may be `Http`, because there you *want* it to read the response and check for a 200. Routing by URL path needs Application Gateway instead.
- **Control plane and data plane are separate permission worlds.** Being Owner lets you manage a storage account but not read its blobs — that needs `Storage Blob Data Reader` or `Contributor`.
- **A role assignment has three parts:** `principalId` (who), `roleDefinitionId` (what), `scope` (**where** it applies — not who it belongs to). Scope inherits downward, so always assign at the narrowest level that works.
- **Role assignment names must be deterministic GUIDs.** `guid(scope, principal, role)` keeps redeploys idempotent; omit an ingredient and two different assignments can collide.
- **Set `principalType: 'ServicePrincipal'`** on role assignments for managed identities, or deployment can fail with "principal not found" while the identity is still replicating.
- **User-assigned identity over system-assigned** when something needs permission *during* resource creation — a system-assigned identity does not exist yet.
- **Guest accounts have mangled UPNs** (`user_domain.com#EXT#@tenant.onmicrosoft.com`). Use the object ID as `--assignee` and the problem disappears.
- **Autoscale quirks:** capacity values and `ChangeCount` values are **strings**, not numbers. `timeWindow` has a five-minute minimum. The metric name is `Percentage CPU` — with a space. Durations are ISO 8601 (`PT5M`).
- **The autoscale metric is averaged across all instances**, so a load test must load all of them. It is also self-diluting: adding a VM lowers the average, which is what stops the rule firing forever.
- **Scale out fast, scale in slow.** Under-provisioning costs customers; over-provisioning costs pennies.
- **Failed deployments are usually free.** Azure validates before creating compute, so iterating early is cheap. `what-if` costs nothing at all.
- **A resource group is free**; only its contents bill. Deleting the group removes manually created role assignments scoped inside it too.

### Linux and the Custom Script Extension

- **Wait for cloud-init before touching apt.** `cloud-init status --wait` first, always. Two systems configure an Azure Ubuntu VM at boot and they will race.
- **apt files package lists under the URL they came from.** Change `sources.list` between `update` and `install` and every downloaded list is orphaned — apt behaves as if no packages exist.
- **The extension's download directory is sequence-numbered and the working directory is set to it.** Use a relative filename; never hardcode `/0/`.
- **File permissions:** `rw-` for owner, group, others, written as numbers (`644` = owner read/write, everyone read). Services such as nginx drop to an unprivileged user (`www-data`), so a file copied by root at mode `600` is unreadable to them.
- **HTTP status codes name the problem:** 403 = found it, refusing (almost always permissions); 404 = not found; 500 = the server broke.
- **`settings` is plain text and visible; `protectedSettings` is encrypted and write-only.** Anything sensitive goes in the second.
- **Chain install steps with `&&`** so a failure stops the chain instead of continuing silently.
- **`az vmss run-command`** runs commands inside a VM with no SSH exposure — both a debugging tool and a load generator. Detach long-running work with `setsid nohup ... &` or the call hangs, and cap it with `timeout` as a safety net.

### Debugging method

- **Read the innermost error.** Azure nests failures; every outer layer just says "something inside me failed." The real message is the last one.
- **Error codes are unique, searchable strings.** Paste them verbatim rather than paraphrasing the symptom.
- **Timeout versus connection refused is diagnostic.** A hang means packets were silently dropped (a firewall, or a load balancer with no healthy backend). An instant refusal means something answered and said no.
- **Gather evidence before theorising.** The first theory in this project was wrong, and only a diagnostic command's output corrected it. Being wrong quickly is fine; staying wrong because nobody checked is not.
- **Pick the test that eliminates the most possibilities**, not the one that confirms your favourite hunch.
- **Read output character by character.** `403` was sitting in plain sight and was initially read as success.
- **Separate "Azure rejected the template" from "the VM ran something and it failed."** The first is fixable before anything boots; the second needs logs from inside the machine (`/var/log/azure/custom-script/handler.log` for this extension).
- **Pick one shell and stay in it.** Most Azure documentation is Bash; `cmd` has no `$(...)`, no single-quote strings, and different loop syntax.

---

## Cost and cleanup

Running cost is roughly $0.10–0.15 per hour (2–4 × `Standard_B1s`, a Standard load balancer, and a Standard public IP). Everything lives in one resource group:

```bash
az group delete --name rg-prj32-vmss --yes --no-wait
```

The manually created role assignment is scoped to a resource inside the group and is removed with it.

---

## Notes and possible extensions

- `Standard_B1s` is a **burstable** size: it accrues CPU credits while idle and can be throttled after sustained full load. Fine for this exercise, but production autoscale workloads normally use non-burstable sizes.
- The SSH public key is referenced from `main.bicepparam` with `loadTextContent()` so that the key file itself stays out of the repository. Private keys are never committed.
- Possible next steps: a second autoscale rule driven by Storage Queue length, HTTPS termination with a certificate from Key Vault, zone redundancy across availability zones, or replacing the load balancer's outbound rule with a NAT Gateway.
