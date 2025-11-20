# Using Standalone PostgreSQL with Firecrawl on Kubernetes

This guide outlines how to configure Firecrawl to use a standalone PostgreSQL database (e.g., AWS RDS, Google Cloud SQL, or a separate HA Postgres cluster) instead of the bundled `nuq-postgres` Docker image.

## 1. Database Requirements

Your standalone PostgreSQL instance must meet the following requirements:

*   **PostgreSQL Version:** 17 is recommended (matches the current `nuq-postgres` image), though 14+ usually works.
*   **Extensions:**
    *   `pgcrypto`: For UUID generation and cryptographic functions.
    *   `pg_cron`: **Critical** for background job cleanup, lock reaping, and maintenance.

### specific Configuration for `pg_cron`

`pg_cron` requires specific configuration in your `postgresql.conf` (or parameter group in cloud providers) to function correctly:

1.  **Shared Preload Libraries:**
    You must add `pg_cron` to `shared_preload_libraries`.
    ```ini
    shared_preload_libraries = 'pg_cron'
    ```
    *(Note: If you have other libraries like `pg_stat_statements`, add them as a comma-separated list: `'pg_stat_statements,pg_cron'`)*

2.  **Cron Database:**
    Tell `pg_cron` which database to run jobs in.
    ```ini
    cron.database_name = 'postgres'
    ```
    *(Replace `'postgres'` with your actual database name if different)*

**Cloud Provider Notes:**
*   **AWS RDS:** Enable `pg_cron` in your Parameter Group. Set `cron.database_name` to your DB name.
*   **Google Cloud SQL:** Add `pg_cron` to your database flags (`cloudsql.enable_pg_cron=on`) and set `cron.database_name`.

## 2. Schema Initialization

Since you are not using the `nuq-postgres` image (which automates this), you must manually apply the schema.

1.  **Get the Schema Script:**
    Download the `nuq.sql` file from the Firecrawl repository:
    [apps/nuq-postgres/nuq.sql](https://github.com/firecrawl/firecrawl/blob/main/apps/nuq-postgres/nuq.sql)

2.  **Run the Script:**
    Connect to your standalone database using `psql` or your preferred client and execute the script.

    ```bash
    psql -h <DB_HOST> -U <DB_USER> -d <DB_NAME> -f apps/nuq-postgres/nuq.sql
    ```

    **What this script does:**
    *   Enables extensions (`pgcrypto`, `pg_cron`).
    *   Creates the `nuq` schema.
    *   Creates necessary types (`job_status`, `group_status`) and tables (`queue_scrape`, `queue_scrape_backlog`, etc.).
    *   Sets up `pg_cron` jobs for cleaning up old jobs, reaping stalled locks, and re-indexing.

## 3. Kubernetes Configuration

Update your Firecrawl Kubernetes deployment (Helm values or Deployment YAML) to point to the new database.

### Environment Variables

Set the `NUQ_DATABASE_URL` environment variable in your **API** and **Worker** containers.

```yaml
env:
  - name: NUQ_DATABASE_URL
    value: "postgres://<USER>:<PASSWORD>@<HOST>:5432/<DB_NAME>?sslmode=require"
```

*   **USER:** Your database username.
*   **PASSWORD:** Your database password.
*   **HOST:** The endpoint/IP of your standalone Postgres instance.
*   **DB_NAME:** The database name where you ran the schema (default is often `postgres`).

### Disable the Internal Postgres Service

If you are using the provided example Kubernetes manifests or Helm chart, ensure you **disable** or **remove** the `nuq-postgres` deployment/statefulset so it doesn't consume resources unnecessarily.

## 4. Verification

1.  **Check Connection:**
    Check the logs of the Firecrawl API pod. It should connect without "Connection Refused" errors.

2.  **Check pg_cron:**
    Connect to your database and run:
    ```sql
    SELECT * FROM cron.job;
    ```
    You should see approximately 6 scheduled jobs (e.g., `nuq_queue_scrape_clean_completed`, `nuq_queue_scrape_lock_reaper`, etc.). If this table is empty or the query fails, `pg_cron` is not set up correctly.
