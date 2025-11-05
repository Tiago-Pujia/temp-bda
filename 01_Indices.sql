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