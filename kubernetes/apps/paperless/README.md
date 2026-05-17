# 📄 Paperless-ngx Deployment

Document management system deployed as a multi-container stack on Kubernetes.

## 🏗️ Architecture

The stack consists of:
- **Paperless-ngx**: The main application webserver.
- **PostgreSQL 16**: Primary data store for document metadata.
- **Redis 7**: Message broker for asynchronous task processing.
- **Tika & Gotenberg**: Add-on services for OCR and document conversion.

## 🔒 Security

- **Authentication**: Integration with Authelia via `Remote-User` header.
- **Secrets**: Database credentials managed via Kubernetes Opaque Secrets.

## 💾 Storage

Uses Longhorn storage class for high availability:
- Data and Media volumes are replicated across cluster nodes.
- DB data is persisted separately to ensure atomic updates.
