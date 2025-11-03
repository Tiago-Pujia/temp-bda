USE Com5600G13;
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name = 'UQ_Persona_Email' AND object_id = OBJECT_ID('app.Tbl_Persona'))
	CREATE UNIQUE INDEX UQ_Persona_Email ON app.Tbl_Persona(email) WHERE email IS NOT NULL;
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name = 'UQ_Persona_CBU_CVU' AND object_id = OBJECT_ID('app.Tbl_Persona'))
CREATE UNIQUE INDEX UQ_Persona_CBU_CVU ON app.Tbl_Persona(CBU_CVU) WHERE CBU_CVU IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_CVU_CBU_PERSONA' AND object_id = OBJECT_ID('app.Tbl_Persona'))
    CREATE NONCLUSTERED INDEX IDX_CVU_CBU_PERSONA ON app.Tbl_Persona (CBU_CVU);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_UF_PERSONA' AND object_id = OBJECT_ID('app.Tbl_UFPersona'))
    CREATE NONCLUSTERED INDEX IDX_UF_PERSONA ON app.Tbl_UFPersona (idPersona, idConsorcio);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_EXPENSA' AND object_id = OBJECT_ID('app.Tbl_Expensa'))
    CREATE NONCLUSTERED INDEX IDX_EXPENSA ON app.Tbl_Expensa (idConsorcio);
GO

-- Índice para expensas por fecha de generación (agrupación mensual)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_EXPENSA_FECHA' AND object_id = OBJECT_ID('app.Tbl_Expensa'))
    CREATE NONCLUSTERED INDEX IDX_EXPENSA_FECHA 
    ON app.Tbl_Expensa (fechaGeneracion, idConsorcio)
    INCLUDE (nroExpensa, montoTotal);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_PAGO' AND object_id = OBJECT_ID('app.Tbl_Pago'))
    CREATE NONCLUSTERED INDEX IDX_PAGO ON app.Tbl_Pago (CBU_CVU, fecha, monto);
GO

-- Índice único filtrado para CBU_CVU (permite múltiples NULL)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_UnidadFuncional_CBU_CVU' AND object_id = OBJECT_ID('app.Tbl_UnidadFuncional'))
    CREATE UNIQUE NONCLUSTERED INDEX UQ_UnidadFuncional_CBU_CVU ON app.Tbl_UnidadFuncional (CBU_CVU) WHERE CBU_CVU IS NOT NULL;
GO

-- Índice para Reporte 1: Flujo de caja semanal (pagos por fecha)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_PAGO_FECHA_MONTO' AND object_id = OBJECT_ID('app.Tbl_Pago'))
    CREATE NONCLUSTERED INDEX IDX_PAGO_FECHA_MONTO 
    ON app.Tbl_Pago (fecha, nroExpensa)
    INCLUDE (monto, idConsorcio);
GO

-- Índice para gastos por expensa (reportes de ingresos vs egresos)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_GASTO_EXPENSA_TIPO' AND object_id = OBJECT_ID('app.Tbl_Gasto'))
    CREATE NONCLUSTERED INDEX IDX_GASTO_EXPENSA_TIPO 
    ON app.Tbl_Gasto (nroExpensa, tipo, idConsorcio)
    INCLUDE (importe, fechaEmision);
GO

-- Índice para Reporte 2: Recaudación por mes y departamento
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_UF_CONSORCIO_DEPTO' AND object_id = OBJECT_ID('app.Tbl_UnidadFuncional'))
    CREATE NONCLUSTERED INDEX IDX_UF_CONSORCIO_DEPTO 
    ON app.Tbl_UnidadFuncional (idConsorcio, piso, departamento);
GO

-- Índice para estado de cuenta (análisis de morosidad - Reporte 5)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_ESTADO_CUENTA_DEUDA' AND object_id = OBJECT_ID('app.Tbl_EstadoCuenta'))
    CREATE NONCLUSTERED INDEX IDX_ESTADO_CUENTA_DEUDA 
    ON app.Tbl_EstadoCuenta (nroUnidadFuncional, idConsorcio)
    INCLUDE (deuda, interesMora, totalAPagar, fecha);
GO

-- Índice para relación UFPersona (identificar propietarios morosos)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_UFPERSONA_UF' AND object_id = OBJECT_ID('app.Tbl_UFPersona'))
    CREATE NONCLUSTERED INDEX IDX_UFPERSONA_UF 
    ON app.Tbl_UFPersona (idConsorcio)
    INCLUDE (idPersona, esInquilino);
GO

-- Índice para datos de contacto de personas
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_PERSONA_CONTACTO' AND object_id = OBJECT_ID('app.Tbl_Persona'))
    CREATE NONCLUSTERED INDEX IDX_PERSONA_CONTACTO 
    ON app.Tbl_Persona (idPersona)
    INCLUDE (nombre, apellido, dni, email, telefono);
GO

-- Índice compuesto para análisis de pagos entre fechas (Reporte 6)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_PAGO_UF_FECHA' AND object_id = OBJECT_ID('app.Tbl_Pago'))
    CREATE NONCLUSTERED INDEX IDX_PAGO_UF_FECHA 
    ON app.Tbl_Pago (nroUnidadFuncional, fecha)
    INCLUDE (monto);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_EXPENSA_FECHA' AND object_id = OBJECT_ID('app.Tbl_Expensa'))
	CREATE UNIQUE NONCLUSTERED INDEX UX_EXPENSA_FECHA
	ON app.Tbl_Expensa (fechaGeneracion, idConsorcio)
	INCLUDE (nroExpensa, montoTotal);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes 
               WHERE name = 'IX_Expensa_SaldoOrder' 
                 AND object_id = OBJECT_ID('app.Tbl_Expensa'))
    CREATE NONCLUSTERED INDEX IX_Expensa_SaldoOrder
    ON app.Tbl_Expensa (idConsorcio, fechaGeneracion, nroExpensa)
    INCLUDE (montoTotal);
GO

-- Para sumar pagos por expensa y filtrar por fecha cuando haga falta
IF NOT EXISTS (SELECT 1 FROM sys.indexes 
               WHERE name = 'IX_Pago_ExpensaConsorcioFecha' 
                 AND object_id = OBJECT_ID('app.Tbl_Pago'))
    CREATE NONCLUSTERED INDEX IX_Pago_ExpensaConsorcioFecha
    ON app.Tbl_Pago (nroExpensa, idConsorcio, fecha)
    INCLUDE (monto, nroUnidadFuncional);
GO

-- Para sumar gastos por expensa+consorcio
IF NOT EXISTS (SELECT 1 FROM sys.indexes 
               WHERE name = 'IX_Gasto_ExpensaConsorcio' 
                 AND object_id = OBJECT_ID('app.Tbl_Gasto'))
    CREATE NONCLUSTERED INDEX IX_Gasto_ExpensaConsorcio
    ON app.Tbl_Gasto (nroExpensa, idConsorcio)
    INCLUDE (importe);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes 
               WHERE name = 'IX_Pago_Week' 
                 AND object_id = OBJECT_ID('app.Tbl_Pago'))
	CREATE NONCLUSTERED INDEX IX_Pago_Week
	ON app.Tbl_Pago (fecha, idConsorcio, nroExpensa)
	INCLUDE (monto, nroUnidadFuncional);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes 
               WHERE name = 'IX_Expensa_Periodo'
                 AND object_id = OBJECT_ID('app.Tbl_Expensa'))
	CREATE NONCLUSTERED INDEX IX_Expensa_Periodo
	ON app.Tbl_Expensa (idConsorcio, fechaGeneracion, nroExpensa)
	INCLUDE (montoTotal);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes 
               WHERE name = 'IDX_Cotizacion_Fecha'
                 AND object_id = OBJECT_ID('api.Tbl_CotizacionDolar'))
CREATE INDEX IDX_Cotizacion_Fecha 
    ON api.Tbl_CotizacionDolar(fechaConsulta DESC);
GO