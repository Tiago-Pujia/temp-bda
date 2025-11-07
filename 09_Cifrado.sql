/*
Archivo: 09_Cifrado.sql
Propósito: Añade columnas cifradas para datos sensibles y encripta los valores
existentes. Incluye vistas y helpers para exponer datos desencriptados de forma
controlada.

Advertencias:
 - El cifrado usado depende de funciones definidas en `seguridad` (pasphrase interna).
 - Revisá políticas de claves y almacenamiento seguro antes de usar en producción.
*/

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
        ADD dniCifrado      VARBINARY(MAX) NULL,      -- DNI encriptado
            emailCifrado    VARBINARY(MAX) NULL,      -- Email encriptado
            telefonoCifrado VARBINARY(MAX) NULL,      -- Teléfono encriptado
            CBU_CVU_Cifrado VARBINARY(MAX) NULL;      -- CBU/CVU encriptado
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
        ADD CBU_CVU_Cifrado VARBINARY(MAX) NULL;
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
        ADD CBU_CVU_Cifrado VARBINARY(MAX) NULL;
END
GO

-- ============================================================
-- 4. ENCRIPTAR DATOS EXISTENTES EN Tbl_Persona
-- ============================================================

-- Actualizar registros existentes en Tbl_Persona cifrando datos sensibles
-- Solo procesa registros donde los datos originales existen y aún no están cifrados
UPDATE p
SET
  dniCifrado       = CASE WHEN p.dni      IS NOT NULL AND (p.dniCifrado IS NULL OR seguridad.fn_DesencriptarTexto(p.dniCifrado) IS NULL)
                          THEN seguridad.fn_EncriptarTexto(CONVERT(NVARCHAR(50),  p.dni)) ELSE p.dniCifrado END,
  emailCifrado     = CASE WHEN p.email    IS NOT NULL AND (p.emailCifrado IS NULL OR seguridad.fn_DesencriptarTexto(p.emailCifrado) IS NULL)
                          THEN seguridad.fn_EncriptarTexto(p.email) ELSE p.emailCifrado END,
  telefonoCifrado  = CASE WHEN p.telefono IS NOT NULL AND (p.telefonoCifrado IS NULL OR seguridad.fn_DesencriptarTexto(p.telefonoCifrado) IS NULL)
                          THEN seguridad.fn_EncriptarTexto(p.telefono) ELSE p.telefonoCifrado END,
  CBU_CVU_Cifrado  = CASE WHEN p.CBU_CVU  IS NOT NULL AND (p.CBU_CVU_Cifrado IS NULL OR seguridad.fn_DesencriptarTexto(p.CBU_CVU_Cifrado) IS NULL)
                          THEN seguridad.fn_EncriptarTexto(p.CBU_CVU) ELSE p.CBU_CVU_Cifrado END
FROM app.Tbl_Persona p;
GO

-- ============================================================
-- 5. ENCRIPTAR DATOS EXISTENTES EN Tbl_UnidadFuncional
-- ============================================================

-- Actualizar registros existentes en Tbl_UnidadFuncional cifrando CBU/CVU
UPDATE uf
SET CBU_CVU_Cifrado = CASE WHEN uf.CBU_CVU IS NOT NULL AND (uf.CBU_CVU_Cifrado IS NULL OR seguridad.fn_DesencriptarTexto(uf.CBU_CVU_Cifrado) IS NULL)
                           THEN seguridad.fn_EncriptarTexto(uf.CBU_CVU) ELSE uf.CBU_CVU_Cifrado END
FROM app.Tbl_UnidadFuncional uf;
GO

-- ============================================================
-- 6. ENCRIPTAR DATOS EXISTENTES EN Tbl_Pago
-- ============================================================

-- Actualizar registros existentes en Tbl_Pago cifrando CBU/CVU
UPDATE pa
SET CBU_CVU_Cifrado = CASE WHEN pa.CBU_CVU IS NOT NULL AND (pa.CBU_CVU_Cifrado IS NULL OR seguridad.fn_DesencriptarTexto(pa.CBU_CVU_Cifrado) IS NULL)
                           THEN seguridad.fn_EncriptarTexto(pa.CBU_CVU) ELSE pa.CBU_CVU_Cifrado END
FROM app.Tbl_Pago pa;
GO

CREATE OR ALTER VIEW app.Vw_PersonaSegura AS
SELECT
    p.idPersona,
    p.nombre,
    p.apellido,
    ISNULL(seguridad.fn_DesencriptarTexto(p.dniCifrado),      CONVERT(NVARCHAR(50),  p.dni))      AS dni,
    ISNULL(seguridad.fn_DesencriptarTexto(p.emailCifrado),    p.email)                              AS email,
    ISNULL(seguridad.fn_DesencriptarTexto(p.telefonoCifrado), p.telefono)                           AS telefono
FROM app.Tbl_Persona p;
GO