# Política de Respaldo – Base de datos **Com5600G13** y artefactos de **Expensas / Ventas / Reportes**

**Fecha:** 2025-11-03  
**Zona horaria:** America/Argentina/Buenos_Aires (ART, UTC−03:00)  
**Alcance:** Base de datos transaccional (SQL Server), *ventas diarias*, *expensas generadas*, y *reportes* (archivos PDF/Excel/etc.).  
**Objetivo:** asegurar restauraciones **punto‑en‑el‑tiempo** (PITR) y disponibilidad histórica confiable para auditoría y operación.

---

## 1) Principios y criterios
- **Modelo 3‑2‑1**: 3 copias de cada respaldo, en **2** tipos de medios, con **1** copia **offsite** (p. ej., almacenamiento en la nube con versión/retención).  
- **Cifrado** de respaldos **en tránsito y en reposo** (clave gestionada en HSM/KMS o cofre de claves).  
- **Compresión + checksum** en backups para reducir tamaño y detectar corrupción.  
- **Backups verificables**: cada corrida registra `VERIFYONLY`/hash y se prueba un **restore de muestra** en entorno aislado.  
- **Trazabilidad**: cada backup se etiqueta con: sistema, fecha/hora ART, tipo, ventana, hash, ubicación primaria y offsite.  
- **Monitoreo y alertas**: fallas o tiempos excesivos de backup/restauración disparan alertas (correo/Slack).

---

## 2) Objetivos de punto de recuperación (RPO)
> RPO = tiempo máximo de datos que se puede perder ante un incidente.

| Componente | RPO objetivo | Justificación |
|---|---:|---|
| **Base de datos Com5600G13** (incluye *ventas diarias* y *expensas*) | **15 minutos** | Cadena de backups de **log** cada 15 min asegura PITR fino durante todo el día. |
| **Reportes generados** (archivos resultantes) | **4 horas** | Toma de snapshots/exports **cada 4 h** + consolidado nocturno. Muchos reportes son reproducibles, pero se prioriza baja pérdida. |

> **RTO** (informativo): 1–4 h para restauración a PITR típico; 4–24 h en escenarios de desastre mayor (DR).

---

## 3) Programación (Schedule) de backups
**Zona horaria:** America/Argentina/Buenos_Aires (ART). Ventanas elegidas fuera de picos.  
Se programan **trabajos SQL Server Agent** (DB) y **tareas del orquestador** (archivos de reportes).

### 3.1 Base de datos (SQL Server)
| Tipo | Frecuencia | Hora(s) ART | Retención | Notas |
|---|---|---|---|---|
| **Full semanal** | **Domingo** | 02:00 | **12 semanas** | Base de referencia principal. Comprimido, con checksum. |
| **Full mensual (copy‑only)** | **Día 1** de cada mes | 03:00 | **13 meses** | Para auditoría y cierres. Copia **inmutable** en repositorio de largo plazo. |
| **Full anual (copy‑only)** | **1 de enero** | 04:00 | **7 años** | Archivo regulatorio (glacier/archival). |
| **Diferencial diario** | **Lun–Sáb** | 02:00 | **35 días** | Reduce ventana de restauración frente a full semanal. |
| **Log de transacciones** | **Cada 15 min** | 24×7 | **14 días** | Habilita **PITR** con granularidad de 15 min. (Mantener cadena continua). |

> **Verificación**: posterior a cada backup se ejecuta **VERIFYONLY** + registro de hash.  
> **Integridad**: **DBCC CHECKDB** los **domingos 03:30** en réplica/restore de prueba (no en productivo).

### 3.2 Artefactos de *reportes generados*
| Tipo | Frecuencia | Hora(s) ART | Retención | Destino |
|---|---|---|---|---|
| **Snapshot rápido** | **Cada 4 h** (09:00, 13:00, 17:00, 21:00) | Ver columna | **14 días** | Storage primario (NAS/SMB/S3) con versionado. |
| **Consolidado nocturno** | **Diario** | 23:30 | **6 meses** | ZIP + índice (manifest) con hashes. |
| **Cierre mensual** | **Día 1** | 03:30 | **13 meses** | Carpeta inmutable con etiqueta del período. |
| **Archivo anual** | **1 de enero** | 04:30 | **7 años** | Almacenamiento de archivo (glacier/low‑cost). |

> **Export de respaldo de “ventas del día”** (opcional): CSV firmado a las **23:55** como instantánea de control, aunque la fuente ya esté cubierta por los backups de DB.

---

## 4) Almacenamiento y replicación
- **Primario**: repositorio local (disco/NAS o Blob estándar) + **versionado** y **bloqueo de eliminación** (WORM) por 14 días.  
- **Offsite**: replicación automática a nube (**S3/Azure Blob** con retención según tabla) en región distinta.  
- **Etiquetado** común: `sistema=Com5600G13, tipo=full/diff/log/snap, fecha=YYYYMMDD-HHMM, hash=..., rpo=...`.  
- **Pruebas de restauración**:  
  - **Semanales**: restaurar última **full + diff + 1 log** en entorno de validación.  
  - **Mensuales**: **PITR** a punto aleatorio del mes.  
  - **Trimestrales**: simulacro **DR** (recuperar sólo con offsite).

---

## 5) Procedimientos de restauración (resumen)
1. **Incidente diario** (pérdida parcial): *RESTORE FULL* (más reciente) → *RESTORE DIF* (del día) → *RESTORE LOGs* hasta el **punto objetivo**.  
2. **Corrupción/Desastre**: usar copia **offsite** más reciente y repetir secuencia.  
3. **Reportes**: reponer desde **snapshot** o **consolidado diario/mensual**.  
4. **Validación**: comparar hashes, conteos y checksums de tablas clave (*expensas*, *ventas*) y ejecutar pruebas funcionales mínimas.

---

## 6) Responsables y alertas
- **Ops/DBA**: operación y monitoreo de jobs, verificación y simulacros.  
- **Owner de negocio**: define períodos de retención, ventanas de mantenimiento y prioriza RPO/RTO.  
- **Alertas**: fallo de job, verificación fallida, cadena de logs rota, ocupación >80% del repositorio, tiempo de backup fuera de umbral.

---

## 7) Justificación
- La combinación **Full + Diferencial + Log** brinda **granularidad** de recuperación (15 min) con **ventanas cortas** de backup.  
- Las **copias mensuales/anuales** cubren auditorías y necesidades regulatorias (*expensas* y cierres contables).  
- Los **snapshots de reportes** limitan el RPO a **4 h** sin impactar el motor; los archivos son restaurables aun si la DB está caída.  
- La regla **3‑2‑1**, el **cifrado** y las **pruebas periódicas** reducen el riesgo operativo y de ransomware.

---

## 8) Matriz de retención (resumen)
| Ítem | Retención |
|---|---|
| Logs (15 min) | **14 días** |
| Diferenciales diarios | **35 días** |
| Full semanal | **12 semanas** |
| Full mensual (copy‑only) | **13 meses** |
| Full anual (copy‑only) | **7 años** |
| Snapshots de reportes (4 h) | **14 días** |
| Consolidado diario de reportes | **6 meses** |
| Cierre mensual de reportes | **13 meses** |
| Archivo anual de reportes | **7 años** |

---

### Notas finales
- Ajustar ventanas si hay procesos nocturnos largos (ETL).  
- Si el crecimiento de **log** es alto, considerar **cada 5–10 min** en horario pico.  
- Documentar *runbooks* con ejemplos de restauración para *“última expensa cerrada”* y *“ventas de ayer 18:00”*.
