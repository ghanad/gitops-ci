# gitops-ci
مخزن مرکزی CI برای ریپوهای GitOps (Infra و Tenantها) در معماری Multi-Repo / Multi-Tenant بر پایه App-of-Apps.

این مخزن برای جلوگیری از **کپی‌کاری CI** در Repoهای متعدد و جلوگیری از **Drift** بین pipelineها ساخته شده است.  
تمام Repoهای GitOps (Repo B: infra و Repo C: tenant/projectها) فقط با `include` کردن template این مخزن، Gateهای استاندارد را اجرا می‌کنند.

---

## هدف
- استانداردسازی و یکپارچه‌سازی GitLab CI برای GitOps
- ایجاد Gate قبل از Merge/Sync:
  - sanity-check روی `application.yml`
  - render کردن Helm Wrapper و Raw Manifests
  - schema validation (kubeconform با schemaهای لوکال برای airgap)
  - policy validation (Kyverno) به صورت CI-only
- مقیاس‌پذیری برای N tenant بدون تغییر بنیادین در معماری

---

## این مخزن چه چیزی را ارائه می‌دهد؟
### 1) CI Templates
- فایل‌های template که Repoهای مصرف‌کننده فقط آن‌ها را `include` می‌کنند.
- هدف: یکسان بودن Jobها، مراحل، و قراردادها در تمام repoها.

### 2) اسکریپت‌های CI
- اسکریپت‌های مشترک که مراحل مختلف pipeline را اجرا می‌کنند:
  - کشف تغییرات (partial/full/skip)
  - render خروجی نهایی به `rendered/`
  - اعتبارسنجی schema و policy
  - تولید artifact و گزارش‌های JUnit برای دیباگ

### 3) Policyهای Kyverno (Baseline)
- سیاست‌های پایه‌ی Kyverno معمولاً به‌صورت مشترک برای همهٔ repoها اجرا می‌شوند.
- مخزن‌های tenant می‌توانند در صورت نیاز، سیاست‌های اختصاصی خودشان را هم اضافه کنند (اختیاری).

---

## قراردادهای معماری GitOps (خلاصه)
این CI مطابق این قراردادها طراحی شده است:
- معماری Multi-Repo و Multi-Tenant بر پایه App-of-Apps
- Root Application در Repo A فقط **Application** می‌سازد (include=**/application.yml) و **منابع واقعی را sync نمی‌کند**
- هر component self-contained است:
  - Helm Wrapper:
    - `application.yml` با `spec.source.path: '.'`
    - `Chart.yaml`, `values.yaml`
  - Raw Manifests:
    - `application.yml` با `spec.source.path: './manifests'`
    - فولدر `manifests/`
- جلوگیری از Double Ownership: منابع واقعی فقط توسط child appها مدیریت می‌شوند.

---

## ساختار این مخزن
> ممکن است با رشد پروژه پوشه‌ها گسترش یابد، اما این هسته ثابت می‌ماند.

- `templates/`
  - قالب اصلی pipeline (GitLab CI include)
- `gitlab-ci-scripts/`
  - اسکریپت‌های اجرایی pipeline
- `policies/kyverno/`
  - policyهای baseline (و دسته‌بندی‌های اضافی در صورت نیاز)

---

## نحوه استفاده در Repoهای مصرف‌کننده
در `.gitlab-ci.yml` هر repo مصرف‌کننده:

```yaml
include:
  - project: "choopan/gitops-ci"
    ref: "v1.0.0"
    file: "/templates/gitops-gate.yml"

variables:
  # مسیر پروژه gitops-ci برای clone شدن توسط jobها
  GITOPS_CI_PROJECT: "choopan/gitops-ci"
  GITOPS_CI_REF: "v1.0.0"

  # مسیر کامپوننت‌ها
  GITOPS_COMPONENTS_DIR: "components"
  # پیشوند اجباری برای metadata.name در application.yml (اختیاری)
  # اگر خالی باشد این بررسی انجام نمی‌شود.
  # مثال: "cluster-a" (در اجرا به شکل "cluster-a-" بررسی می‌شود)
  APP_NAME_PREFIX: ""
  # متغیر قدیمی (برای سازگاری)
  # GITOPS_APPLICATION_NAME_PREFIX: ""

  # انتخاب policy set ها
  KYVERNO_POLICYSETS: "baseline"
  # مثال: baseline + tenant
  # KYVERNO_POLICYSETS: "baseline,tenant"
````

### انتخاب Kyverno PolicySet

* `baseline`:

  * policyهای مشترک از داخل همین مخزن اجرا می‌شوند.
* `tenant`:

  * اگر در repo مصرف‌کننده مسیر `policies/kyverno/tenant/` وجود داشته باشد، policyهای آن هم اجرا می‌شود.
* امکان افزودن setهای دیگر در آینده وجود دارد (مثل `security`, `strict`, ...)

---

## دسترسی GitLab (Job Token Access)

Jobها برای دسترسی به اسکریپت‌ها و policyهای baseline، این repo را با `CI_JOB_TOKEN` clone می‌کنند.
بنابراین باید در پروژه `gitops-ci` تنظیمات زیر انجام شده باشد:

* فعال بودن allowlist برای CI job token
* اضافه شدن گروه/پروژه‌های GitOps (Repo B و Repo Cها) به allowlist

---

## خروجی‌های pipeline

* `rendered/` : خروجی نهایی رندر شده برای هر component
* `out/` : گزارش‌ها، لاگ‌ها و JUnit ها برای دیباگ

---

## اصول توسعه و تغییرات

* تغییرات روی pipeline باید در این repo انجام شود (نه در repoهای مصرف‌کننده).
* برای rollout کنترل‌شده:

  * از tag/release استفاده شود (مثلاً `v1.0.0`, `v1.1.0`)
  * repoهای مصرف‌کننده با تغییر `ref` به نسخه جدید مهاجرت کنند.

---

## نکات مهم

* این CI برای جلوگیری از drift و double ownership طراحی شده است.
* policyها در CI صرفاً نقش gate دارند و جایگزین enforce واقعی در cluster نیستند.
* در صورت اضافه شدن policyهای Mutate در Kyverno admission، باید مراقب drift با ArgoCD بود.

---

## Changelog

### v1.0.1 

* Expanded the BATS unit test coverage for CI scripts, including change-detection, XML escaping, and application prefix validation tests.
* Added a GitHub Actions workflow to run the BATS test suite.
* Improved kubeconform validation to handle manifests without YAML separators and to count resources more reliably, plus comprehensive test coverage.
* Fixed JUnit XML escaping and improved Kyverno violation logging for clearer failure messages.
* Updated README guidance, including corrected `yq` installation and clearer BATS execution instructions.


## 🧪 Unit Tests

We use [BATS (Bash Automated Testing System)](https://github.com/bats-core/bats-core) to validate the CI scripts logic.

### Prerequisites

Ensure you have `bats` and `yq` (v4+) installed.

```bash
# Install BATS
sudo apt install -y bats

# Install yq (binary download)
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod a+x /usr/local/bin/yq

# execute 
```
bats tests
```
