USE Com5600G13;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_CVU_CBU_PERSONA' AND object_id = OBJECT_ID('app.Tbl_Persona'))
    CREATE NONCLUSTERED INDEX IDX_CVU_CBU_PERSONA ON app.Tbl_Persona (CBU_CVU);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_UF_PERSONA' AND object_id = OBJECT_ID('app.Tbl_UFPersona'))
    CREATE NONCLUSTERED INDEX IDX_UF_PERSONA ON app.Tbl_UFPersona (idPersona, idUnidadFuncional, idConsorcio);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_EXPENSA' AND object_id = OBJECT_ID('app.Tbl_Expensa'))
    CREATE NONCLUSTERED INDEX IDX_EXPENSA ON app.Tbl_Expensa (idConsorcio);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_PAGO' AND object_id = OBJECT_ID('app.Tbl_Pago'))
    CREATE NONCLUSTERED INDEX IDX_PAGO ON app.Tbl_Pago (CBU_CVU, fecha, monto);
GO
