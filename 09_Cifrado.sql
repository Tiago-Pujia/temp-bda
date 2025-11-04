USE Com5600G13;
GO

IF COL_LENGTH('app.Tbl_Persona', 'dniCifrado') IS NULL
BEGIN
    ALTER TABLE app.Tbl_Persona
        ADD dniCifrado      VARBINARY(512) NULL,
            emailCifrado    VARBINARY(512) NULL,
            telefonoCifrado VARBINARY(512) NULL,
            CBU_CVU_Cifrado VARBINARY(512) NULL;
END
GO

IF COL_LENGTH('app.Tbl_UnidadFuncional', 'CBU_CVU_Cifrado') IS NULL
BEGIN
    ALTER TABLE app.Tbl_UnidadFuncional
        ADD CBU_CVU_Cifrado VARBINARY(512) NULL;
END
GO

IF COL_LENGTH('app.Tbl_Pago', 'CBU_CVU_Cifrado') IS NULL
BEGIN
    ALTER TABLE app.Tbl_Pago
        ADD CBU_CVU_Cifrado VARBINARY(512) NULL;
END
GO

-- Personas ya cargadas
UPDATE p
SET dniCifrado       = seguridad.fn_EncriptarTexto(CONVERT(NVARCHAR(50), p.dni)),
    emailCifrado     = seguridad.fn_EncriptarTexto(p.email),
    telefonoCifrado  = seguridad.fn_EncriptarTexto(p.telefono),
    CBU_CVU_Cifrado  = seguridad.fn_EncriptarTexto(p.CBU_CVU)
FROM app.Tbl_Persona p
WHERE (p.dniCifrado       IS NULL AND p.dni       IS NOT NULL)
   OR (p.emailCifrado     IS NULL AND p.email     IS NOT NULL)
   OR (p.telefonoCifrado  IS NULL AND p.telefono  IS NOT NULL)
   OR (p.CBU_CVU_Cifrado  IS NULL AND p.CBU_CVU   IS NOT NULL);
GO

-- UF ya cargadas
UPDATE uf
SET CBU_CVU_Cifrado = seguridad.fn_EncriptarTexto(uf.CBU_CVU)
FROM app.Tbl_UnidadFuncional uf
WHERE uf.CBU_CVU_Cifrado IS NULL
  AND uf.CBU_CVU IS NOT NULL;
GO

-- Pagos ya cargados
UPDATE pa
SET CBU_CVU_Cifrado = seguridad.fn_EncriptarTexto(pa.CBU_CVU)
FROM app.Tbl_Pago pa
WHERE pa.CBU_CVU_Cifrado IS NULL
  AND pa.CBU_CVU IS NOT NULL;
GO