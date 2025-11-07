/*
Archivo: 10_Triggers.sql
Propósito: Triggers que mantienen columnas cifradas sincronizadas y gatillan
recalculos al insertar/actualizar pagos (recalculo de mora, etc.).

Notas:
 - Los triggers invocan funciones de cifrado y procedimientos de recálculo; cuidado
   con operaciones masivas (bulk inserts) porque pueden generar carga adicional.
 - Si necesitás desactivar temporalmente la lógica (ej. para migraciones grandes),
   considerá deshabilitar triggers y luego re-ejecutar un proceso de sincronización.
*/

USE Com5600G13;
GO

-- PERSONA
/*
Trigger: app.trg_Tbl_Persona_Cifrado
Propósito: mantener sincronizadas versiones cifradas de campos sensibles
 (dni, email, telefono, CBU/CVU) cuando se insertan o actualizan filas en
 `app.Tbl_Persona`.

Notas:
 - Usa `seguridad.fn_EncriptarTexto` para generar VARBINARY; esa función usa
   ENCRYPTBYPASSPHRASE con una passphrase embebida (ver `03_Funciones.sql`).
 - El trigger corre AFTER INSERT, UPDATE; para cargas masivas considerar
   deshabilitar temporalmente y ejecutar un job que haga la conversión por lotes.
 - No hace rollback en caso de fallo, pero un error dentro del trigger bloqueará
   la transacción que provocó la inserción/actualización.
*/
CREATE OR ALTER TRIGGER app.trg_Tbl_Persona_Cifrado
ON app.Tbl_Persona
AFTER INSERT, UPDATE
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE p
  SET dniCifrado       = seguridad.fn_EncriptarTexto(CONVERT(NVARCHAR(50), p.dni)),
      emailCifrado     = seguridad.fn_EncriptarTexto(p.email),
      telefonoCifrado  = seguridad.fn_EncriptarTexto(p.telefono),
      CBU_CVU_Cifrado  = seguridad.fn_EncriptarTexto(p.CBU_CVU)
  FROM app.Tbl_Persona p
  INNER JOIN inserted i
    ON i.idPersona = p.idPersona;
END;
GO

-- UNIDAD FUNCIONAL
/*
Trigger: app.trg_Tbl_UnidadFuncional_Cifrado
Propósito: actualizar la versión cifrada del CBU/CVU cuando cambia la UF.
Notas: igual consideraciones de performance y seguridad que el trigger de Persona.
*/
CREATE OR ALTER TRIGGER app.trg_Tbl_UnidadFuncional_Cifrado
ON app.Tbl_UnidadFuncional
AFTER INSERT, UPDATE
AS
BEGIN
  SET NOCOUNT ON;

  UPDATE uf
  SET CBU_CVU_Cifrado = seguridad.fn_EncriptarTexto(uf.CBU_CVU)
  FROM app.Tbl_UnidadFuncional uf
  INNER JOIN inserted i
    ON i.idUnidadFuncional = uf.idUnidadFuncional;
END;
GO

-- PAGO
/*
Trigger: app.trg_Tbl_Pago_Cifrado
Propósito: en pagos nuevos o actualizados, mantener el valor cifrado del
CBU/CVU asociado al pago.
Notas:
 - Evitar lógica pesada en triggers de pagos si el sistema realiza muchos inserts
   simultáneos; preferible procesamiento asíncrono en lotes para cargas masivas.
*/
CREATE OR ALTER TRIGGER app.trg_Tbl_Pago_Cifrado
ON app.Tbl_Pago
AFTER INSERT, UPDATE
AS
BEGIN
  SET NOCOUNT ON;

  UPDATE pa
  SET CBU_CVU_Cifrado = seguridad.fn_EncriptarTexto(pa.CBU_CVU)
  FROM app.Tbl_Pago pa
  INNER JOIN inserted i
    ON i.idPago = pa.idPago;
END;
GO

CREATE OR ALTER TRIGGER app.tr_Tbl_Pago_RecalcularMora
ON app.Tbl_Pago
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
  SET NOCOUNT ON;

  /*
  Trigger: app.tr_Tbl_Pago_RecalcularMora
  Propósito: cuando hay cambios en pagos (insert/update/delete) recalcula
  los montos pagados, la deuda, intereses por mora y total a pagar en
  `app.Tbl_EstadoCuenta` para los estados de cuenta afectados.

  Detalles:
   - Suma los pagos por idEstadoCuenta y actualiza los campos relevantes.
   - Aplica reglas de mora basadas en fechas de vencimiento (fechaVto1/2).
   - El trigger asume que `inserted`/`deleted` contienen idEstadoCuenta cuando
     corresponda; en otros casos puede no afectar filas.

  Consideraciones:
   - Operaciones en bloque pueden disparar recalculos para muchas filas; este
     trigger es síncrono y puede aumentar la latencia de las DML.
   - Para migraciones masivas evaluar deshabilitar y ejecutar un proceso de
     recalculo por lotes fuera de la transacción.
  */

  DECLARE @Hoy DATE = CAST(GETDATE() AS DATE);

  ;WITH afectados AS (
      SELECT idEstadoCuenta FROM inserted WHERE idEstadoCuenta IS NOT NULL
      UNION
      SELECT idEstadoCuenta FROM deleted  WHERE idEstadoCuenta IS NOT NULL
  ),
  agg_pagos AS (
      SELECT p.idEstadoCuenta,
             SUM(p.monto) AS montoPagado,
             MAX(p.fecha) AS fechaUltimoPago
      FROM app.Tbl_Pago p
      JOIN afectados a ON a.idEstadoCuenta = p.idEstadoCuenta
      GROUP BY p.idEstadoCuenta
  )
  UPDATE ec
     SET ec.pagoRecibido = ISNULL(ap.montoPagado, 0),
         ec.deuda = CASE
                      WHEN calc.baseMes <= ISNULL(ap.montoPagado, 0) THEN 0
                      ELSE calc.baseMes - ISNULL(ap.montoPagado, 0)
                    END,
         ec.interesMora =
             CASE
               WHEN (calc.baseMes - ISNULL(ap.montoPagado,0)) <= 0 THEN 0
               WHEN @Hoy <= ex.fechaVto1 THEN 0
               WHEN @Hoy > ex.fechaVto1
                    AND (ex.fechaVto2 IS NULL OR @Hoy <= ex.fechaVto2)
                    THEN ROUND(0.02 * (calc.baseMes - ISNULL(ap.montoPagado,0)), 2)
               WHEN ex.fechaVto2 IS NOT NULL AND @Hoy > ex.fechaVto2
                    THEN ROUND(0.05 * (calc.baseMes - ISNULL(ap.montoPagado,0)), 2)
               ELSE 0
             END,
         ec.totalAPagar =
             CASE
               WHEN (calc.baseMes - ISNULL(ap.montoPagado,0)) <= 0 THEN 0
               ELSE (calc.baseMes - ISNULL(ap.montoPagado,0)) +
                    CASE
                      WHEN @Hoy <= ex.fechaVto1 THEN 0
                      WHEN @Hoy > ex.fechaVto1
                           AND (ex.fechaVto2 IS NULL OR @Hoy <= ex.fechaVto2)
                           THEN ROUND(0.02 * (calc.baseMes - ISNULL(ap.montoPagado,0)), 2)
                      WHEN ex.fechaVto2 IS NOT NULL AND @Hoy > ex.fechaVto2
                           THEN ROUND(0.05 * (calc.baseMes - ISNULL(ap.montoPagado,0)), 2)
                      ELSE 0
                    END
             END
  FROM app.Tbl_EstadoCuenta ec
  JOIN afectados a  ON a.idEstadoCuenta = ec.idEstadoCuenta
  LEFT JOIN agg_pagos ap ON ap.idEstadoCuenta = ec.idEstadoCuenta
  JOIN app.Tbl_Expensa ex ON ex.idConsorcio = ec.idConsorcio AND ex.nroExpensa = ec.nroExpensa
  CROSS APPLY (SELECT baseMes = ISNULL(ec.expensasOrdinarias,0) + ISNULL(ec.expensasExtraordinarias,0)) AS calc;
END
GO

ENABLE TRIGGER app.tr_Tbl_Pago_RecalcularMora ON app.Tbl_Pago;

EXEC app.Sp_RecalcularMoraEstadosCuenta_Todo;  -- @FechaCorte = GETDATE()