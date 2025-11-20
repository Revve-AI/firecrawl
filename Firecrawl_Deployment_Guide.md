# Firecrawl Integration & Deployment Guide for Revve

This document outlines the architecture, deployment strategy, and configuration required to host Firecrawl as the crawling engine for **Revve-web**.

## 1. Architecture Overview

Firecrawl operates as an asynchronous microservices architecture. It accepts crawl requests from Revve, processes them using a specialized queue system, and pushes the results (clean Markdown) back to Revve via Webhooks for RAG indexing.

### Integration Diagram

![Integration Diagram](integration_diagram.png)

### Data Flow
1.  **Job Submission:** Revve sends a request (`POST /v1/crawl`) to the **Firecrawl API**.
2.  **Queuing:** The job is stored in **PostgreSQL** (using the custom "NuQ" schema for high-throughput scraping).
3.  **Processing:** 
    *   **`nuq-worker`**: Picks up scraping jobs, controls the browser (Playwright), and parses content (HTML/PDF/DOCX).
    *   **`worker`**: Handles orchestration and complex "Deep Research" tasks.
4.  **Callback:** As pages are crawled, Firecrawl sends a `POST` webhook to Revve.
5.  **RAG Ingestion:** Revve receives the Markdown, chunks it, and embeds it into its own Vector Database.

---

## 2. Infrastructure Prerequisites

### Database & Cache Strategy
**Recommendation:** Reuse your existing managed infrastructure (e.g., Azure Managed Instances) to reduce cost and maintenance overhead.

*   **PostgreSQL (Azure Database for PostgreSQL - Flexible Server):**
    *   **Important:** Create a specific logical database (e.g., named `firecrawl`) within your existing Postgres instance. Do not share the schema with Revve application tables to avoid conflicts.
    *   **Extensions:** Ensure `pgcrypto` and `pg_cron` are enabled on this database.
*   **Redis (Azure Cache for Redis):**
    *   You can reuse the existing Redis instance.
    *   Firecrawl uses standard keys. Ideally, use a separate Redis database index (e.g., `DB 1`) or ensure your environment allows key separation.

---

## 3. Kubernetes Deployment Guide

You must deploy all four components listed below. They serve distinct roles and are all required for a functional system.

### Component Breakdown

1.  **`playwright-service.yaml`**
    *   **Role:** A headless browser service (connects to Chrome/Chromium).
    *   **Why needed:** The workers do not run browsers inside their own containers; they connect to this service via WebSocket to render JavaScript-heavy sites.
2.  **`api.yaml`**
    *   **Role:** The REST API gateway.
    *   **Why needed:** It is the entry point for Revve to submit jobs (`/v1/crawl`) and for the admin dashboard.
3.  **`worker.yaml`** (Standard Worker)
    *   **Role:** Orchestration & Lightweight Tasks.
    *   **Why needed:** It handles "Deep Research" flows, LLM extraction orchestration, and finalizes crawl batches.
4.  **`nuq-worker.yaml`** (Scraping Worker)
    *   **Role:** The Heavy Lifter.
    *   **Why needed:** This worker processes the actual "Scrape Queue" (NuQ) in Postgres. **This is the component that primarily needs scaling.**

### Recommended Sizing (Resource Requests/Limits)

| Service | CPU Request | RAM Request | RAM Limit | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **API** | 0.5 vCPU | 512Mi | 1Gi | Lightweight HTTP server. |
| **Playwright** | 1.0 vCPU | 2Gi | 4Gi | Memory intensive (browser tabs). Scale alongside `nuq-worker`. |
| **Worker** | 0.5 vCPU | 1Gi | 2Gi | Handles orchestration logic. |
| **NuQ Worker** | 1.0 vCPU | 2Gi | 4Gi | Handles heavy parsing and logic. |

### Deployment Commands

```bash
kubectl apply -f playwright-service.yaml
kubectl apply -f api.yaml
kubectl apply -f worker.yaml
kubectl apply -f nuq-worker.yaml
```

---

## 4. Environment Variables

These variables must be set in your `ConfigMap` or `Secret` (e.g., `firecrawl-secret`) and injected into the deployments.

| Variable | Description | Example |
| :--- | :--- |:---|
| `DATABASE_URL` | Connection string to the `firecrawl` Postgres DB. | `postgresql://user:pass@azure-pg:5432/firecrawl?sslmode=require` |
| `NUQ_DATABASE_URL` | Same as above (Firecrawl uses this specifically for the queue). | `postgresql://user:pass@azure-pg:5432/firecrawl?sslmode=require` |
| `REDIS_URL` | Connection string to Azure Redis. | `redis://:pass@azure-redis:6379` |
| `PLAYWRIGHT_MICROSERVICE_URL`| Internal K8s DNS to the playwright service. | `http://playwright-service:3000` |
| `USE_DB_AUTHENTICATION` | Set to `true` to enable API Key management via DB. | `true` |
| `BULL_AUTH_KEY` | This key lets you access the queue admin panel. | `Changeme` |
| `PORT` | Internal port. | `3002` |
| **Azure OpenAI Config** | | |
| `AZURE_OPENAI_API_KEY` | API Key for Azure OpenAI Service. | `...` |
| `AZURE_OPENAI_RESOURCE_NAME`| Name of your Azure OpenAI Resource. | `my-openai-resource` |
| `MODEL_NAME` | **Important:** Set this to your Azure Deployment Name. | `gpt-4o-deployment` |

---

## 5. Autoscaling (KEDA)

Since Firecrawl uses two different queues, we recommend implementing **KEDA (Kubernetes Event-driven Autoscaling)** for efficient resource usage.

### A. Scaling `nuq-worker` (Postgres Queue)
This worker pulls from the SQL table `nuq.queue_scrape`.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: nuq-worker-scaler
spec:
  scaleTargetRef:
    name: nuq-worker
  minReplicaCount: 2
  maxReplicaCount: 20
  triggers:
    - type: postgresql
      metadata:
        connectionFromEnv: NUQ_DATABASE_URL
        # Scale up if there are >5 queued jobs per pod
        targetQueryValue: "5"
        query: "SELECT count(*) FROM nuq.queue_scrape WHERE status = 'queued'"
```

### B. Scaling `worker` (Redis Queue)
This worker handles orchestration via Redis (BullMQ).

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-scaler
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 1
  maxReplicaCount: 5
  triggers:
    - type: redis
      metadata:
        addressFromEnv: REDIS_URL
        listName: "{deepResearchQueue}"
        listLength: "10"
```

---

## 6. FAQ & Operational Details

### Which LLM models are used and for what purpose?
Firecrawl primarily uses **OpenAI models** (`gpt-4o`, `gpt-4o-mini`, and occasionally `gpt-3.5-turbo`).

**Azure OpenAI Configuration:**
To use Azure OpenAI instead of the public API:
1.  Set `AZURE_OPENAI_API_KEY` and `AZURE_OPENAI_RESOURCE_NAME`.
2.  **Crucial:** Set the `MODEL_NAME` environment variable to match your **Deployment Name** in Azure AI Studio (e.g., if you deployed `gpt-4o` as `my-gpt4o-deployment`, set `MODEL_NAME=my-gpt4o-deployment`).

**Purpose:**
1.  **LLM Extraction:** Converts raw HTML into structured JSON based on schema requirements.
2.  **Metadata Generation:** Generates titles or descriptions if missing from the HTML.
3.  **Planning:** In "Deep Research" mode, the LLM plans navigation paths.

### Where is the crawled data stored? Is it embedded into RAG directly?
1.  **Storage:** Firecrawl stores the crawled Markdown **temporarily** in the PostgreSQL database as a job result.
2.  **RAG Integration:** Firecrawl **does not** embed the data itself.
3.  **The Handover:** Firecrawl sends the raw Markdown to Revve via **Webhook**. Revve is responsible for chunking, embedding, and saving to the Vector DB.

### Can it crawl websites with Captcha/Anti-bot?
**Yes.** Firecrawl includes a "stealth" mode that mimics human behavior. For extremely aggressive anti-bot sites (e.g., Cloudflare Turnstile), you should configure a **Proxy Service** (like Smartproxy or BrightData) and provide the proxy URL in the `PROXY_SERVER` environment variable.

### Is Media Parsing (PDF, DOCX, Images) fully implemented?
**Yes.**
*   **PDF:** Uses a dual strategy (high-fidelity parser service fallback to local `pdf-parse` library).
*   **DOCX/Office:** Uses a Rust-based converter to convert Office documents directly to HTML/Markdown.
*   **Images:** Can use Vision models (GPT-4o) to generate alt-text descriptions for images if enabled.

### How should we handle Security Vulnerabilities?
1.  **Container Scanning:** Use tools like Azure Container Registry (ACR) or Trivy to scan Firecrawl Docker images (`ghcr.io/firecrawl/firecrawl`) before deployment.
2.  **Network Isolation:** Do **not** expose the Firecrawl API to the public internet. Keep it within the private K8s VNET, accessible only by Revve-web.
3.  **API Limits:** Set strict quotas on the `OPENAI_API_KEY` used by Firecrawl.
