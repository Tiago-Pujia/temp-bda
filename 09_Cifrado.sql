-- Este script agrega columnas cifradas para datos personales sensibles
-- y encripta los datos existentes en las tablas

USE Com5600G13;
GO

-- ============================================================
-- 1. AGREGAR COLUMNAS CIFRADAS EN TABLA Tbl_Persona
-- ============================================================

-- Verificar si la columna 'dniCifrado' no existe en Tbl_Persona antes de agregar
IF COL_LENGTH('app.Tbl_Persona', 'dniCifrado') IS NULL
BEGIN
    -- Agregar columnas para almacenar datos sensibles encriptados
    ALTER TABLE app.Tbl_Persona
        ADD dniCifrado      VARBINARY(512) NULL,      -- DNI encriptado
            emailCifrado    VARBINARY(512) NULL,      -- Email encriptado
            telefonoCifrado VARBINARY(512) NULL,      -- Teléfono encriptado
            CBU_CVU_Cifrado VARBINARY(512) NULL;      -- CBU/CVU encriptado
END
GO

-- ============================================================
-- 2. AGREGAR COLUMNAS CIFRADAS EN TABLA Tbl_UnidadFuncional
-- ============================================================

-- Verificar si la columna 'CBU_CVU_Cifrado' no existe en Tbl_UnidadFuncional
IF COL_LENGTH('app.Tbl_UnidadFuncional', 'CBU_CVU_Cifrado') IS NULL
BEGIN
    -- Agregar columna para CBU/CVU encriptado en unidades funcionales
    ALTER TABLE app.Tbl_UnidadFuncional
        ADD CBU_CVU_Cifrado VARBINARY(512) NULL;
END
GO

-- ============================================================
-- 3. AGREGAR COLUMNAS CIFRADAS EN TABLA Tbl_Pago
-- ============================================================

-- Verificar si la columna 'CBU_CVU_Cifrado' no existe en Tbl_Pago
IF COL_LENGTH('app.Tbl_Pago', 'CBU_CVU_Cifrado') IS NULL
BEGIN
    -- Agregar columna para CBU/CVU encriptado en pagos
    ALTER TABLE app.Tbl_Pago
        ADD CBU_CVU_Cifrado VARBINARY(512) NULL;
END
GO

-- ============================================================
-- 4. ENCRIPTAR DATOS EXISTENTES EN Tbl_Persona
-- ============================================================

-- Actualizar registros existentes en Tbl_Persona cifrando datos sensibles
-- Solo procesa registros donde los datos originales existen y aún no están cifrados
UPDATE p
SET dniCifrado       = seguridad.fn_EncriptarTexto(CONVERT(NVARCHAR(50), p.dni)),  -- Convertir DNI numérico a texto y encriptar
    emailCifrado     = seguridad.fn_EncriptarTexto(p.email),                        -- Encriptar email
    telefonoCifrado  = seguridad.fn_EncriptarTexto(p.telefono),                     -- Encriptar teléfono
    CBU_CVU_Cifrado  = seguridad.fn_EncriptarTexto(p.CBU_CVU)                       -- Encriptar CBU/CVU
FROM app.Tbl_Persona p
WHERE (p.dniCifrado       IS NULL AND p.dni       IS NOT NULL)   -- Solo si DNI existe y no está cifrado
   OR (p.emailCifrado     IS NULL AND p.email     IS NOT NULL)   -- Solo si email existe y no está cifrado
   OR (p.telefonoCifrado  IS NULL AND p.telefono  IS NOT NULL)   -- Solo si teléfono existe y no está cifrado
   OR (p.CBU_CVU_Cifrado  IS NULL AND p.CBU_CVU   IS NOT NULL);  -- Solo si CBU/CVU existe y no está cifrado
GO

-- ============================================================
-- 5. ENCRIPTAR DATOS EXISTENTES EN Tbl_UnidadFuncional
-- ============================================================

-- Actualizar registros existentes en Tbl_UnidadFuncional cifrando CBU/CVU
UPDATE uf
SET CBU_CVU_Cifrado = seguridad.fn_EncriptarTexto(uf.CBU_CVU)  -- Encriptar CBU/CVU de unidades funcionales
FROM app.Tbl_UnidadFuncional uf
WHERE uf.CBU_CVU_Cifrado IS NULL    -- Solo si no está cifrado
  AND uf.CBU_CVU IS NOT NULL;       -- Y existe dato original
GO

-- ============================================================
-- 6. ENCRIPTAR DATOS EXISTENTES EN Tbl_Pago
-- ============================================================

-- Actualizar registros existentes en Tbl_Pago cifrando CBU/CVU
UPDATE pa
SET CBU_CVU_Cifrado = seguridad.fn_EncriptarTexto(pa.CBU_CVU)  -- Encriptar CBU/CVU de pagos
FROM app.Tbl_Pago pa
WHERE pa.CBU_CVU_Cifrado IS NULL    -- Solo si no está cifrado
  AND pa.CBU_CVU IS NOT NULL;       -- Y existe dato original
GO