# GitOps Validation Pipeline

پایپلاین GitLab CI برای اعتبارسنجی خودکار ArgoCD Applications و Kubernetes manifests

## 📋 فهرست مطالب

- [معرفی](#معرفی)
- [ویژگی‌های کلیدی](#ویژگیهای-کلیدی)
- [پیش‌نیازها](#پیشنیازها)
  - [Docker Image استاندارد](#docker-image-استاندارد)
  - [ساخت Docker Image روی ماشین متصل به اینترنت](#ساخت-docker-image-روی-ماشین-متصل-به-اینترنت)
  - [خلاصه Dockerfile](#خلاصه-dockerfile)
- [ساختار Repository](#ساختار-repository)
- [نحوه کار Pipeline](#نحوه-کار-pipeline)
  - [مراحل اجرا](#مراحل-اجرا)
  - [Smart Diff چگونه کار می‌کند؟](#smart-diff-چگونه-کار-میکند)
- [تنظیمات و پیکربندی](#تنظیمات-و-پیکربندی)
  - [متغیرهای قابل تنظیم](#متغیرهای-قابل-تنظیم)
  - [دو نوع Application پشتیبانی می‌شود](#دو-نوع-application-پشتیبانی-میشود)
  - [رفتار spec.source.path در Pipeline](#رفتار-specsourcepath-در-pipeline)
  - [Helm Dependencies در محیط Airgap](#helm-dependencies-در-محیط-airgap)
- [خروجی‌ها و Artifacts](#خروجیها-و-artifacts)
  - [JUnit XML Report](#junit-xml-report)
  - [فایل‌های تولید شده](#فایلهای-تولید-شده)
  - [نمایش نتایج در GitLab](#نمایش-نتایج-در-gitlab)
- [عیب‌یابی](#عیبیابی)
  - [خطاهای رایج و راه‌حل‌ها](#خطاهای-رایج-و-راهحلها)
  - [دیدن لاگ‌های تفصیلی](#دیدن-لاگهای-تفصیلی)
- [سوالات متداول (FAQ)](#سوالات-متداول-faq)

---

## معرفی

این پایپلاین به صورت خودکار ArgoCD Applicationهای موجود در repository را قبل از merge به main branch بررسی می‌کند تا:

- **خطاهای Syntax** در YAML ها شناسایی شوند
- **قوانین Kubernetes** رعایت شده باشند
- **Helm Charts** به درستی render شوند
- **اشتباهات پیکربندی** قبل از deploy پیدا شوند

### چرا این Pipeline مهم است؟

❌ **بدون این Pipeline:**
- خطاها بعد از deploy کشف می‌شوند
- ArgoCD ممکن است نتواند Application را sync کند
- زمان debug طولانی می‌شود
- Production ممکن است تحت تأثیر قرار بگیرد

✅ **با این Pipeline:**
- خطاها در مرحله MR/Push شناسایی می‌شوند
- فقط configuration های معتبر merge می‌شوند
- رندر و validate قبل از ArgoCD انجام می‌شود
- کاهش زمان debug و rollback

---

## ویژگیهای کلیدی

### 🎯 Smart Diff Detection
- فقط component های تغییر کرده را validate می‌کند
- در صورت تغییر فایل‌های حساس (مثل `.gitlab-ci.yml`، `templates/`، `scripts/`) همه component ها را بررسی می‌کند
- صرفه‌جویی در زمان CI و منابع

### 🔒 امنیت پیشرفته
- جلوگیری از path traversal attacks (`../../../etc/passwd`)
- validation کاراکترهای مجاز در نام‌ها و مسیرها
- جلوگیری از مسیرهای ناامن در `spec.source.path`

### 📊 گزارش‌دهی حرفه‌ای
- تولید JUnit XML برای نمایش در GitLab UI
- لاگ‌های تفصیلی برای debug
- خروجی rendered manifests برای بررسی دستی

### ⚡ بهینه‌سازی عملکرد
- Cache کردن Helm dependencies
- Timeout برای عملیات طولانی
- Early exit در صورت خطای sanity check

### 🌐 سازگار با Airgap
- kubeconform به صورت **آفلاین** اجرا می‌شود
- schemaها داخل Docker image قرار داده می‌شوند
- در CI از `file://` استفاده می‌شود و **نباید** `-schema-location default` فعال باشد

---

## پیشنیازها

### Docker Image استاندارد

Pipeline باید با این image اجرا شود:

```

jfrog-baloot.mahsan.co/docker/argo-git-validator:v1.32.1

````

✅ تگ `v1.32.1` نشان می‌دهد این image برای Kubernetes **v1.32.1** آماده شده است (ابزارها + schemaهای Kubernetes همین نسخه).

> نکته: در `.gitlab-ci.yml` نیز باید `KUBERNETES_VERSION: "1.32.1"` باشد تا با schemaهای baked شده match شود.

---

### ساخت Docker Image روی ماشین متصل به اینترنت

به دلیل Airgap بودن محیط runner، image باید روی یک ماشین دارای اینترنت ساخته شود و سپس به registry داخلی push شود.

#### مراحل پیشنهادی
1) روی ماشین متصل به اینترنت، Dockerfile را build کنید  
2) image را با تگ نسخه Kubernetes تگ بزنید (مثلاً `v1.32.1`)  
3) image را به registry داخلی push کنید  
4) در محیط Airgap فقط همین image را pull کرده و در CI استفاده کنید

#### Build / Push (نمونه)
```bash
docker build -t jfrog-baloot.mahsan.co/docker/argo-git-validator:v1.32.1 .
docker push jfrog-baloot.mahsan.co/docker/argo-git-validator:v1.32.1
````

---

### خلاصه Dockerfile

این Docker image باید این موارد را فراهم کند:

1. ابزارهای پایه:

* `bash`
* `git`
* `coreutils` (برای `timeout` و ابزارهای استاندارد)
* `findutils`

2. ابزارهای validation:

* `yq` (v4+)
* `helm` (v3+)
* `kubeconform`

3. schemaهای Kubernetes برای نسخه مورد نظر:

* `v1.32.1-standalone-strict`
* مسیر پیشنهادی:

  * `/opt/kubeconform/schemas/v1.32.1-standalone-strict`

4. ست کردن ENV:

* `KUBECONFORM_SCHEMA_DIR=/opt/kubeconform/schemas`

#### نمونه Dockerfile (خلاصه و قابل فهم)

> این نمونه صرفاً برای توضیح ساختار است. نسخه واقعی شما می‌تواند multi-stage باشد و باینری‌ها و schemaها را دانلود/کپی کند.

```dockerfile
FROM alpine:3.20

# basics
RUN apk add --no-cache bash git ca-certificates coreutils findutils curl tar gzip

# add yq / helm / kubeconform (download binaries into /usr/local/bin)
# ... (omitted)

# bake k8s schemas (v1.32.1-standalone-strict) into image
# COPY v1.32.1-standalone-strict /opt/kubeconform/schemas/v1.32.1-standalone-strict

ENV KUBECONFORM_SCHEMA_DIR=/opt/kubeconform/schemas
```

---

## ساختار Repository

```
your-gitops-repo/
├── .gitlab-ci.yml              # این pipeline
├── components/                 # تمام ArgoCD Applications
│   ├── app1/
│   │   ├── application.yml     # ArgoCD Application manifest
│   │   ├── Chart.yaml          # (برای Helm)
│   │   ├── Chart.lock          # (توصیه می‌شود)
│   │   ├── values.yaml
│   │
│   ├── app2/
│   │   ├── application.yml
│   │   └── manifests/          # (برای raw manifests)
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       └── ingress.yaml
│   │
│   └── app-database/
│       └── application.yml
│
├── templates/                  # (اختیاری) Shared templates
└── scripts/                    # (اختیاری) Helper scripts
```

---

## نحوه کار Pipeline

### مراحل اجرا

```
┌─────────────────────────────────────────────┐
│  1. Sanity Checks                           │
│     - چک metadata.name در همه فایل‌ها       │
│     - چک duplicate names                    │
│     - اگر fail شد → متوقف می‌شود            │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│  2. Smart Diff Detection                    │
│     - تشخیص فایل‌های تغییر کرده             │
│     - تعیین component های target           │
│     - FULL SCAN اگر لازم باشد               │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│  3. Component Validation Loop               │
│     برای هر component:                      │
│     ├─ Validate application.yml             │
│     ├─ Render (Helm یا Raw)                 │
│     └─ Kubeconform validation               │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│  4. Generate Reports                        │
│     - JUnit XML                             │
│     - Validation logs                       │
│     - Rendered manifests                    │
└─────────────────────────────────────────────┘
```

---

### Smart Diff چگونه کار می‌کند؟

#### حالت 1: Merge Request

```bash
# فایل‌های تغییر کرده بین base و target branch
git diff base...target
```

#### حالت 2: Push به Main

```bash
# فایل‌های تغییر کرده در commit جدید
git diff before..after
```

#### حالت 3: Full Scan

Full Scan در این موارد اجرا می‌شود:

* ✅ اولین commit یا force push
* ✅ تغییر فایل‌های حساس (match با `IMPACTFUL_FILES_REGEX`)
* ✅ تغییر فایل‌هایی خارج از `components/`
* ✅ عدم دسترسی به commit های قبلی

---

## تنظیمات و پیکربندی

### متغیرهای قابل تنظیم

```yaml
variables:
  # نسخه Kubernetes برای validation (باید با tag image match باشد)
  KUBERNETES_VERSION: "1.32.1"

  # پوشه خروجی artifacts
  OUT_DIR: "out"

  # Regex برای فایل‌های حساس (FULL SCAN trigger)
  IMPACTFUL_FILES_REGEX: "^(\.gitlab-ci\.yml|templates/|scripts/)"

  # آیا CRDها در Helm render شوند؟
  HELM_INCLUDE_CRDS: "false"

  # حداکثر زمان برای عملیات Helm (ثانیه)
  HELM_TIMEOUT: "300"

  # مسیر schemaها داخل image (Airgap)
  KUBECONFORM_SCHEMA_DIR: "/opt/kubeconform/schemas"
```

---

### تنظیمات GitLab

```yaml
# در .gitlab-ci.yml خود image مناسب را تنظیم کنید:
image: jfrog-baloot.mahsan.co/docker/argo-git-validator:v1.32.1
```

---

### دو نوع Application پشتیبانی می‌شود

#### 1️⃣ Helm

برای Application هایی که از Helm chart استفاده می‌کنند:

```yaml
# components/my-app/application.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
spec:
  project: default
  source:
    repoURL: https://gitlab.com/your-org/your-repo
    targetRevision: main
    path: .  # Helm
    helm:
      valueFiles:
        - values.yaml
        - values-prod.yaml
  destination:
    namespace: production
```

**ساختار پوشه:**

```
components/my-app/
├── application.yml
├── Chart.yaml       # الزامی
├── Chart.lock       # توصیه می‌شود
├── values.yaml
└── values-prod.yaml
```

#### 2️⃣ Raw Manifests

برای Application هایی که raw YAML دارند:

```yaml
# components/my-app/application.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
spec:
  project: default
  source:
    repoURL: https://gitlab.com/your-org/your-repo
    targetRevision: main
    path: ./manifests
  destination:
    namespace: production
```

**ساختار پوشه:**

```
components/my-app/
├── application.yml
└── manifests/       # الزامی
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml
```

---

### رفتار spec.source.path در Pipeline

Pipeline مسیر `spec.source.path` را resolve می‌کند:

* اگر خالی یا `.` باشد → مسیر component همان `components/<name>/`
* اگر `manifests` یا `./manifests` باشد → `components/<name>/manifests`
* اگر `./something` باشد → `components/<name>/something`
* در غیر این صورت → مسیر به عنوان مسیر **نسبی از ریشه repo** در نظر گرفته می‌شود

✅ مسیرهای ناامن reject می‌شوند:

* absolute path (`/etc/...`)
* شامل `..`

---

### Helm Dependencies در محیط Airgap

اگر chart شما dependency دارد:

✅ توصیه‌های ضروری:

* حتماً `Chart.lock` را commit کنید (برای reproducible build)
* dependencyها باید در محیط runner قابل دسترسی باشند

در محیط Airgap معمولاً دسترسی به repoهای عمومی ندارید؛ بنابراین یکی از این رویکردها لازم است:

1. **Vendoring**

* dependencyها را در داخل repo یا artifact داخلی نگه دارید

2. **Internal Helm Repository**

* repo داخلی (Artifactory/Nexus/Registry داخلی) داشته باشید
* dependencyها را mirror کنید و `repository:` را به آدرس داخلی تغییر دهید

⚠️ نکته:

* دستوراتی مثل `helm repo add bitnami ...` فقط وقتی معنی دارد که runner به اینترنت/آن repo دسترسی داشته باشد.

---

## خروجیها و Artifacts

### JUnit XML Report

GitLab به صورت خودکار نتایج تست را نمایش می‌دهد:

```
Pipeline → Tests tab
  ✅ sanity-check-missing-names (passed)
  ✅ sanity-check-duplicates (passed)
  ✅ app1 (passed) - 45s
  ❌ app2 (failed) - 38s
     └─ helm lint failed; kubeconform validation failed
  ✅ app-database (passed) - 37s
```

### فایلهای تولید شده

```
out/
├── junit.xml                    # JUnit report برای GitLab
├── validation.log               # لاگ کامل تمام مراحل
├── my-app.yaml                  # Rendered Kubernetes manifests
├── my-app.stderr                # خطاها و warnings از Helm (اگر Helm باشد)
└── ...
```

> خروجی kubeconform در همان `validation.log` ثبت می‌شود (و در صورت نیاز در log job هم قابل مشاهده است).

### نمایش نتایج در GitLab

#### در Merge Request:

1. **Overview tab** → نمایش pipeline status
2. **Pipelines tab** → لینک به job log
3. **Tests tab** → نمایش گزارش JUnit

#### در Pipeline:

1. کلیک روی job `validate-components`
2. مشاهده لاگ real-time
3. دانلود artifacts از سمت راست

---

## عیبیابی

### خطاهای رایج و راهحلها

#### ❌ "Required tool is not installed"

**خطا:**

```
⛔ CRITICAL: Required tool "kubeconform" is not installed in the image
```

**راه‌حل:**

* Docker image باید ابزارهای مورد نیاز را داشته باشد
* بررسی سریع:

```bash
docker run --rm jfrog-baloot.mahsan.co/docker/argo-git-validator:v1.32.1 which kubeconform
```

---

#### ❌ "Missing metadata.name"

**خطا:**

```
⛔ CRITICAL: application.yml files missing metadata.name:
   - components/my-app/application.yml
```

**راه‌حل:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
spec:
  ...
```

---

#### ❌ "Duplicate Application names"

**خطا:**

```
⛔ CRITICAL: Duplicate Application names detected:
my-app
```

**راه‌حل:**

* دو `application.yml` مختلف نباید `metadata.name` یکسان داشته باشند
* نام‌های unique برای هر component انتخاب کنید

---

#### ❌ "Application name must start with prefix"

**خطا:**

```
❌ Invalid Application name 'my-app' (expected prefix: cluster-a-)
```

**راه‌حل:**

* متغیر `GITOPS_APPLICATION_NAME_PREFIX` را در GitLab CI تنظیم کنید (مثلاً `cluster-a-`)
* `metadata.name` هر application باید با این prefix شروع شود
* اگر نمی‌خواهید این قانون اعمال شود، مقدار این متغیر را خالی بگذارید

---

#### ❌ "Invalid characters in metadata.name"

**خطا:**

```
❌ ERROR: Invalid characters in metadata.name: my app/name
   Allowed: alphanumeric, dash, underscore, dot
```

**راه‌حل:**

```yaml
# نادرست:
metadata:
  name: "my app/name"

# درست:
metadata:
  name: "my-app-name"
```

**کاراکترهای مجاز:** `a-z`, `A-Z`, `0-9`, `-`, `_`, `.`

---

#### ❌ "Path traversal attempt detected"

**خطا:**

```
❌ ERROR: Path traversal attempt detected in valueFile: ../../../secrets.yaml
```

**راه‌حل:**

```yaml
# نادرست:
helm:
  valueFiles:
    - ../../../secrets.yaml
    - /etc/passwd

# درست:
helm:
  valueFiles:
    - values.yaml
    - env/prod-values.yaml
```

---

#### ❌ "Chart.yaml missing"

**خطا:**

```
❌ ERROR: Source path is "." but Chart.yaml is missing
```

**راه‌حل:**

* اگر `spec.source.path: .` دارید، باید `Chart.yaml` وجود داشته باشد
* یا `Chart.yaml` اضافه کنید یا به raw manifests تغییر دهید:

```yaml
spec:
  source:
    path: ./manifests
```

---

#### ❌ "Helm dependency build failed"

**خطا:**

```
❌ ERROR: Helm dependency build failed or timed out
```

**راه‌حل (Airgap-friendly):**

1. بررسی dependencies در `Chart.yaml`
2. اطمینان از اینکه dependencyها از repo داخلی/ویندور شده قابل دسترسی هستند
3. ساخت و commit کردن `Chart.lock`:

```bash
cd components/my-app/
helm dependency build
git add Chart.lock
git commit -m "Add Chart.lock for reproducible builds"
```

---

#### ❌ "Kubeconform validation failed"

**خطا:**

```
❌ ERROR: Kubeconform validation failed
```

**راه‌حل:**

1. مشاهده جزئیات در artifact:

```bash
cat out/validation.log
cat out/my-app.yaml
```

2. خطاهای رایج:

* Missing required fields (مثل `metadata.name`)
* Invalid resource types
* Schema violations

3. مثال خطا و راه‌حل:

```yaml
# نادرست:
apiVersion: v1
kind: Service
metadata: {}  # ← name لازم است

# درست:
apiVersion: v1
kind: Service
metadata:
  name: my-service
```

---

#### ❌ "Local schemas not found" (ویژه Airgap)

**نشانه:**

* Pipeline قبل از اجرای kubeconform fail می‌شود و می‌گوید schema directory وجود ندارد.

**راه‌حل:**

* مطمئن شوید داخل image این مسیر وجود دارد:

  * `/opt/kubeconform/schemas/v1.32.1-standalone-strict`
* و `KUBECONFORM_SCHEMA_DIR` درست ست شده
* و `KUBERNETES_VERSION` با schema version یکی است

---

#### ⚠️ "Chart.lock is missing"

**هشدار:**

```
⚠️ WARNING: Chart.lock is missing. Builds may be non-deterministic.
```

**راه‌حل (توصیه می‌شود):**

```bash
cd components/my-app/
helm dependency build
git add Chart.lock
git commit -m "Add Chart.lock for reproducible builds"
```

**توضیح:** `Chart.lock` باعث می‌شود نسخه‌های dependency ها ثابت بمانند.

---

### دیدن لاگهای تفصیلی

#### در GitLab UI:

1. رفتن به Pipeline → Job `validate-components`
2. کلیک روی **Browse** در بخش Artifacts
3. دانلود `validation.log` برای مشاهده کامل

---

## سوالات متداول (FAQ)

### Q: چرا باید از این Pipeline استفاده کنم؟

**A:** جلوگیری از merge تنظیمات نادرست که باعث fail شدن sync/deploy می‌شود.

### Q: آیا می‌توانم این Pipeline را برای Kustomize استفاده کنم؟

**A:** این نسخه فقط Helm و Raw manifests را پشتیبانی می‌کند. برای Kustomize باید validation مخصوص اضافه شود.

### Q: چند وقت طول می‌کشد؟

**A:**

* تغییر کوچک (1-2 component): حدود 1-2 دقیقه
* Full scan (تعداد زیاد component): بسته به تعداد و dependency ها ممکن است بیشتر شود

### Q: آیا می‌توانم IMPACTFUL_FILES_REGEX را customize کنم؟

**A:** بله:

```yaml
variables:
  IMPACTFUL_FILES_REGEX: "^(\.gitlab-ci\.yml|global-config/|base-templates/)"
```

### Q: خطای "git fetch failed" چه معنایی دارد؟

**A:** Pipeline نتوانسته commit قبلی را پیدا کند. در این صورت Full Scan اجرا می‌شود.
