/*
Archivo: 01_Indices.sql
Propósito: Crea índices pensados para consultas frecuentes (pagos, expensas, estados de
cuenta y búsqueda por CBU/CBU). Estos índices ayudan en performance de reportes y joins.

Notas:
 - Revisá los índices INCLUDE según el tamaño real de las filas; mantener demasiados
         includes puede aumentar IO en escrituras.
 - Algunos índices son UNIQUE para proteger integridad (ej: CBU/CBU). Si cambiás
         longitud/colaciones revisá estas restricciones.

Consejos prácticos (tono humano):
 - Antes de agregar un índice nuevo, mirá primero los planes de consulta y el
     patrón de filtros (WHERE) y joins. Un índice que no se usa solo agrega costo
     en escrituras.
 - Los INCLUDE son útiles para evitar lookups cuando las consultas piden columnas
     adicionales; no incluyas columnas grandes si las consultas rara vez las piden.
 - Si una consulta filtra por rango de fechas, ordena las columnas del índice
     poniendo la parte de igualdad primero y el rango después (p.ej. idConsorcio,
     fechaGeneracion).
*/

USE Com5600G13;
GO

/** Tbl_UFPersona -> idPersona y idConsorcio **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_UF_PERSONA' AND object_id = OBJECT_ID('app.Tbl_UFPersona'))
    CREATE NONCLUSTERED INDEX IDX_UF_PERSONA 
    ON app.Tbl_UFPersona (idPersona, idConsorcio);
GO

/** Tbl_UnidadFuncional -> CVU/CBU **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_UnidadFuncional_CBU_CVU' AND object_id = OBJECT_ID('app.Tbl_UnidadFuncional'))
    CREATE UNIQUE NONCLUSTERED INDEX UQ_UnidadFuncional_CBU_CVU 
    ON app.Tbl_UnidadFuncional (CBU_CVU) WHERE CBU_CVU IS NOT NULL;
GO

/** Tbl_UnidadFuncional -> piso, departamento **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_UF_CONSORCIO_DEPTO' AND object_id = OBJECT_ID('app.Tbl_UnidadFuncional'))
    CREATE NONCLUSTERED INDEX IDX_UF_CONSORCIO_DEPTO 
    ON app.Tbl_UnidadFuncional (piso, departamento);
GO

/** Tbl_EstadoCuenta -> nroUnidadFuncional, idConsorcio **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_ESTADO_CUENTA_DEUDA' AND object_id = OBJECT_ID('app.Tbl_EstadoCuenta'))
    CREATE NONCLUSTERED INDEX IDX_ESTADO_CUENTA_DEUDA 
    ON app.Tbl_EstadoCuenta (nroUnidadFuncional, idConsorcio)
    INCLUDE (deuda, interesMora, totalAPagar, fecha);
GO

/** Tbl_EstadoCuenta -> idConsorcio, nroUnidadFuncional, nroExpensa **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_EC_ConsorcioUFExpensa' AND object_id = OBJECT_ID('app.Tbl_EstadoCuenta'))
CREATE INDEX IX_EC_ConsorcioUFExpensa
  ON app.Tbl_EstadoCuenta(idConsorcio, nroUnidadFuncional, nroExpensa);
GO

/** Tbl_Pago -> nroUnidadFuncional, fecha **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_PAGO_UF_FECHA'AND object_id = OBJECT_ID('app.Tbl_Pago'))
    CREATE NONCLUSTERED INDEX IDX_PAGO_UF_FECHA 
    ON app.Tbl_Pago (nroUnidadFuncional, fecha)
    INCLUDE (monto);
GO

/** Tbl_Expensa -> fechaGeneracion, idConsorcio **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_EXPENSA_FECHA' AND object_id = OBJECT_ID('app.Tbl_Expensa'))
	CREATE UNIQUE NONCLUSTERED INDEX UX_EXPENSA_FECHA
	ON app.Tbl_Expensa (fechaGeneracion, idConsorcio)
	INCLUDE (nroExpensa, montoTotal);
GO

/** Tbl_Pago -> nroExpensa, idConsorcio, fecha**/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Pago_ExpensaConsorcioFecha' AND object_id = OBJECT_ID('app.Tbl_Pago'))
    CREATE NONCLUSTERED INDEX IX_Pago_ExpensaConsorcioFecha
    ON app.Tbl_Pago (nroExpensa, idConsorcio, fecha)
    INCLUDE (monto, nroUnidadFuncional);
GO

/** Tbl_Gasto -> nroExpensa, idConsorcio **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Gasto_ExpensaConsorcio' AND object_id = OBJECT_ID('app.Tbl_Gasto'))
    CREATE NONCLUSTERED INDEX IX_Gasto_ExpensaConsorcio
    ON app.Tbl_Gasto (nroExpensa, idConsorcio)
    INCLUDE (importe, tipo);
GO

/** Tbl_Gasto -> idConsorcio, nroExpensa, tipo **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Gasto_ConsorcioExpensaTipo' AND object_id = OBJECT_ID('app.Tbl_Gasto'))
CREATE INDEX IX_Gasto_ConsorcioExpensaTipo
  ON app.Tbl_Gasto(idConsorcio, nroExpensa, tipo) INCLUDE(importe);
GO

/** Tbl_Pago -> fecha, idConsorcio, nroExpensa **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Pago_Week' AND object_id = OBJECT_ID('app.Tbl_Pago'))
	CREATE NONCLUSTERED INDEX IX_Pago_Week
	ON app.Tbl_Pago (fecha, idConsorcio, nroExpensa)
	INCLUDE (monto, nroUnidadFuncional);
GO

/** Tbl_Expensa -> idConsorcio, fechaGeneracion, nroExpensa **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Expensa_Periodo'AND object_id = OBJECT_ID('app.Tbl_Expensa'))
	CREATE NONCLUSTERED INDEX IX_Expensa_Periodo
	ON app.Tbl_Expensa (idConsorcio, fechaGeneracion, nroExpensa)
	INCLUDE (montoTotal);
GO

/** Tbl_CotizacionDolar -> fechaConsulta **/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Cotizacion_Fecha'AND object_id = OBJECT_ID('api.Tbl_CotizacionDolar'))
    CREATE INDEX IDX_Cotizacion_Fecha 
    ON api.Tbl_CotizacionDolar(fechaConsulta DESC);
GO