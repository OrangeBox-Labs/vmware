#!/bin/bash
# ================================================================================================
# vmware-vmdk-compressor.sh - Comprime discos VMDK en backups (con soporte para espacios y sparse)
# ================================================================================================
# DESCRIPCIÓN:
#   Busca archivos *-flat.vmdk en el directorio BASE_DIR, los comprime con pigz
#   (compresión paralela), verifica la integridad del archivo comprimido y
#   elimina el original si la verificación es exitosa.
#
#   PRESERVA EL FORMATO SPARSE usando tar --sparse en compresión y descompresión.
#   MANEJA NOMBRES DE ARCHIVO CON ESPACIOS usando comillas y -f - en tar.
#
# USO:
#   ./vmware-vmdk-compressor.sh
#
# Descomprimir (manual):
#   pigz -dc archivo.tar.gz | tar -xpf -
#
# AUTOR: Felipe Román froman@orangebox.cl -OrangeBox-
# FECHA: 2026-08-20
# ==============================================================================

# ==============================================================================
# CONFIGURACIÓN
# ==============================================================================

# Directorio base donde se encuentran los respaldos de VMs
BASE_DIR="/storage/VMware/"

# Path de tar (cambiar si se compiló a mano una versión más nueva que la que trae el sistema.)
#TAR=/usr/local/bin/tar
TAR=$(which tar)

# Archivo de log principal (todo el proceso)
LOG_FILE="/var/log/vmdk_compress.log"

# Número de hilos de CPU para pigz (por defecto, usar todos los cores disponibles)
NPROC=$(nproc 2>/dev/null || echo 4)

# Nivel de compresión de pigz (1=mas rapido, 9=mas comprimido, 6=balance)
COMPRESSION_LEVEL=6

# Espacio libre mínimo requerido en GB para poder comprimir
MIN_FREE_SPACE_GB=50

# ==============================================================================
# COLORES PARA LA SALIDA EN PANTALLA
# ==============================================================================

RED='\033[0;31m'     # Rojo para errores
GREEN='\033[0;32m'   # Verde para éxitos
YELLOW='\033[1;33m'  # Amarillo para advertencias
BLUE='\033[0;34m'    # Azul para información
MAGENTA='\033[0;35m' # Magenta para destacar
CYAN='\033[0;36m'    # Cian para encabezados
NC='\033[0m'         # No Color (reset)

# ==============================================================================
# VARIABLES GLOBALES
# ==============================================================================

# Array asociativo para almacenar los datos del reporte
# Clave: nombre de la VM, Valor: datos separados por pipe (|)
declare -A VM_REPORT

# Variables para estadísticas del proceso
TOTAL_PROCESSED=0
TOTAL_SUCCESS=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0

# ==============================================================================
# FUNCIONES AUXILIARES
# ==============================================================================

format_time() {
  local seconds="$1"

  if [ -z "$seconds" ] || ! [[ "$seconds" =~ ^[0-9.]+$ ]]; then
    seconds=0
  fi

  local int_part=$(echo "$seconds" | cut -d. -f1)
  if [ -z "$int_part" ] || ! [[ "$int_part" =~ ^[0-9]+$ ]]; then
    int_part=0
  fi

  if [ "$int_part" -le 0 ]; then
    echo "0s"
    return
  fi

  local hours=$((int_part / 3600))
  local mins=$(((int_part % 3600) / 60))
  local secs=$((int_part % 60))

  if [ "$hours" -gt 0 ]; then
    echo "${hours}h ${mins}m ${secs}s"
  elif [ "$mins" -gt 0 ]; then
    echo "${mins}m ${secs}s"
  else
    echo "${secs}s"
  fi
}

format_time_decimal() {
  local seconds="$1"

  if [ -z "$seconds" ] || ! [[ "$seconds" =~ ^[0-9.]+$ ]]; then
    seconds=0
  fi

  local int_part=$(echo "$seconds" | cut -d. -f1)
  if [ -z "$int_part" ] || ! [[ "$int_part" =~ ^[0-9]+$ ]]; then
    int_part=0
  fi

  if [ "$int_part" -le 0 ]; then
    echo "0s"
    return
  fi

  if [ "$int_part" -lt 60 ]; then
    echo "${int_part}s"
    return
  fi

  local hours=$((int_part / 3600))
  local mins=$(((int_part % 3600) / 60))
  local secs=$((int_part % 60))

  if [ "$hours" -gt 0 ]; then
    echo "${hours}h ${mins}m ${secs}s"
  elif [ "$mins" -gt 0 ]; then
    echo "${mins}m ${secs}s"
  else
    echo "${secs}s"
  fi
}

log() {
  local msg="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  # Si la salida es una terminal, mostrar con colores
  if [ -t 1 ]; then
    echo -e "[$timestamp] $msg" | tee -a "$LOG_FILE"
  else
    # Si no es terminal (log file), eliminar códigos ANSI
    local clean_msg=$(echo -e "$msg" | sed -E 's/\x1b\[[0-9;]*m//g')
    echo "[$timestamp] $clean_msg" | tee -a "$LOG_FILE"
  fi
}

# ==============================================================================
# FUNCIONES DE VERIFICACIÓN
# ==============================================================================

check_space() {
  local dir="$1"

  local available=$(df -BG "$dir" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')

  [ -z "$available" ] && available=0

  if [ "$available" -lt "$MIN_FREE_SPACE_GB" ]; then
    log "${RED}⚠️  Espacio insuficiente: $available GB disponible (mínimo $MIN_FREE_SPACE_GB GB)${NC}"
    return 1
  fi
  return 0
}

# ==============================================================================
# is_vmdk_being_written - CORREGIDA (4 mediciones con 5s = 15s)
# ==============================================================================

is_vmdk_being_written() {
  local vmdk_file="$1"
  local dir=$(dirname "$vmdk_file")

  if [ -f "$dir/.lock" ] || [ -f "$dir/.backup.lock" ]; then
    log "  ⏳ Archivo de lock detectado (.lock)"
    return 0
  fi

  if ls "$dir"/.backup_* 2>/dev/null | grep -q .; then
    log "  ⏳ Backup en curso detectado (.backup_*)"
    return 0
  fi

  # ============================================================
  # USAR du -s (bloques de 1K) y convertir a bytes
  # ============================================================
  local blocks1=$(du -s "$vmdk_file" 2>/dev/null | cut -f1)
  if [ -z "$blocks1" ] || [ "$blocks1" -eq 0 ]; then
    log "  ⚠️  Archivo vacío o no accesible"
    return 0
  fi

  local size1=$((blocks1 * 1024))

  log "  📊 Monitoreando crecimiento (4 mediciones con 5s de espera)..."
  log "  📏 Medición 1: $(numfmt --to=iec $size1 2>/dev/null || echo $size1)"

  sleep 5
  local blocks2=$(du -s "$vmdk_file" 2>/dev/null | cut -f1)
  if [ -z "$blocks2" ]; then
    log "  ⚠️  Archivo desapareció"
    return 0
  fi
  local size2=$((blocks2 * 1024))
  log "  📏 Medición 2: $(numfmt --to=iec $size2 2>/dev/null || echo $size2)"

  if [ "$size1" != "$size2" ]; then
    log "  ⏳ Archivo está creciendo ($(numfmt --to=iec $size1 2>/dev/null || echo $size1) → $(numfmt --to=iec $size2 2>/dev/null || echo $size2))"
    return 0
  fi

  sleep 5
  local blocks3=$(du -s "$vmdk_file" 2>/dev/null | cut -f1)
  if [ -z "$blocks3" ]; then
    log "  ⚠️  Archivo desapareció"
    return 0
  fi
  local size3=$((blocks3 * 1024))
  log "  📏 Medición 3: $(numfmt --to=iec $size3 2>/dev/null || echo $size3)"

  if [ "$size2" != "$size3" ]; then
    log "  ⏳ Archivo está creciendo ($(numfmt --to=iec $size2 2>/dev/null || echo $size2) → $(numfmt --to=iec $size3 2>/dev/null || echo $size3))"
    return 0
  fi

  sleep 5
  local blocks4=$(du -s "$vmdk_file" 2>/dev/null | cut -f1)
  if [ -z "$blocks4" ]; then
    log "  ⚠️  Archivo desapareció"
    return 0
  fi
  local size4=$((blocks4 * 1024))
  log "  📏 Medición 4: $(numfmt --to=iec $size4 2>/dev/null || echo $size4)"

  if [ "$size3" != "$size4" ]; then
    log "  ⏳ Archivo está creciendo ($(numfmt --to=iec $size3 2>/dev/null || echo $size3) → $(numfmt --to=iec $size4 2>/dev/null || echo $size4))"
    return 0
  fi

  log "  ✅ Archivo estable ($(numfmt --to=iec $size1 2>/dev/null || echo $size1))"
  return 1
}

# ==============================================================================
# FUNCIÓN PRINCIPAL DE COMPRESIÓN
# ==============================================================================

compress_vmdk() {
  local vmdk_file="$1"
  local dir=$(dirname "$vmdk_file")
  local vm_name=$(basename "$dir" | cut -d'-' -f1)
  local backup_date=$(basename "$dir" | sed 's/^[^-]*-//')

  log "${YELLOW}📦 Procesando: ${BLUE}$vm_name${NC} ($backup_date) - $(basename "$vmdk_file")"

  # PASO 1: Verificar si el archivo ya fue comprimido
  if [ -f "${vmdk_file}.tar.gz" ]; then
    log "  ⏭️  Ya existe ${vmdk_file}.tar.gz, saltando..."
    return 2
  fi

  # PASO 2: Verificar si el archivo está siendo escrito
  if is_vmdk_being_written "$vmdk_file"; then
    log "  ⏳ Archivo en uso (backup en proceso), saltando..."
    return 2
  fi

  # PASO 3: Verificar espacio en disco
  if ! check_space "$dir"; then
    log "  ❌ Espacio insuficiente, saltando..."
    return 1
  fi

  # ============================================================
  # PASO 4: Obtener TAMAÑO REAL EN DISCO (usando du -s)
  # ============================================================
  local blocks=$(du -s "$vmdk_file" 2>/dev/null | cut -f1)
  if [ -z "$blocks" ] || [ "$blocks" -eq 0 ]; then
    log "  ❌ Archivo inválido o vacío"
    return 1
  fi

  local orig_bytes=$((blocks * 1024))
  local orig_size_gb=$(echo "scale=2; $orig_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null)
  [ -z "$orig_size_gb" ] && orig_size_gb="0.00"

  # Mostrar también el tamaño lógico para referencia
  local logical_bytes=$(stat -c%s "$vmdk_file" 2>/dev/null)
  local logical_size_gb=$(echo "scale=2; $logical_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null)
  [ -z "$logical_size_gb" ] && logical_size_gb="0.00"

  log "  📊 Tamaño real: ${orig_size_gb} GB (lógico: ${logical_size_gb} GB)"

  # PASO 5: Iniciar temporizador
  local start_time=$(date +%s.%N 2>/dev/null || date +%s)

  # ============================================================
  # OBTENER DIRECTORIO Y NOMBRE DEL ARCHIVO
  # ============================================================
  local vmdk_dir=$(dirname "$vmdk_file")
  local vmdk_name=$(basename "$vmdk_file")

  # PASO 6: COMPRIMIR (PRESERVA SPARSE Y MANEJA ESPACIOS)
  log "  🧵 Comprimiendo con $TAR --sparse + pigz ($NPROC hilos, nivel $COMPRESSION_LEVEL)..."

  if (cd "$vmdk_dir" && $TAR -cf - --sparse --hole-detection=seek "$vmdk_name" 2>/dev/null) | pigz -p "$NPROC" -"${COMPRESSION_LEVEL}" >"${vmdk_file}.tar.gz"; then

    # PASO 7: Calcular tiempo de compresión
    local end_time=$(date +%s.%N 2>/dev/null || date +%s)
    local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null)
    [ -z "$duration" ] && duration=0

    # PASO 8: VERIFICAR INTEGRIDAD
    log "  🔍 Verificando integridad del archivo comprimido..."

    local verify_ok=0
    if command -v igzip &>/dev/null; then
      if igzip -t "${vmdk_file}.tar.gz" 2>/dev/null; then
        verify_ok=1
      fi
    elif command -v pigz &>/dev/null; then
      if pigz -t -p "$NPROC" "${vmdk_file}.tar.gz" 2>/dev/null; then
        verify_ok=1
      fi
    else
      if gzip -t "${vmdk_file}.tar.gz" 2>/dev/null; then
        verify_ok=1
      fi
    fi

    if [ "$verify_ok" -eq 1 ]; then
      # ============================================================
      # PASO 9: Calcular métricas con TAMAÑO REAL
      # ============================================================
      local comp_blocks=$(du -s "${vmdk_file}.tar.gz" 2>/dev/null | cut -f1)
      [ -z "$comp_blocks" ] && comp_blocks=0

      local comp_bytes=$((comp_blocks * 1024))
      local comp_size_gb=$(echo "scale=2; $comp_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null)
      [ -z "$comp_size_gb" ] && comp_size_gb="0.00"

      local ratio=$(echo "scale=2; $orig_bytes / $comp_bytes" | bc 2>/dev/null)
      [ -z "$ratio" ] || [ "$ratio" = "0" ] || [ "$ratio" = "." ] && ratio="1.00"

      local speed=$(echo "scale=2; ($orig_bytes / 1024 / 1024) / $duration" | bc 2>/dev/null)
      [ -z "$speed" ] || [ "$speed" = "0" ] || [ "$speed" = "." ] && speed="0.00"

      local ahorro=$(echo "scale=2; 100 - ($comp_bytes * 100 / $orig_bytes)" | bc 2>/dev/null)
      [ -z "$ahorro" ] && ahorro="0"

      local formatted_duration=$(format_time_decimal "$duration")

      log "  ✅ Compresión exitosa en ${formatted_duration}"
      log "  📊 Comprimido: ${comp_size_gb} GB (ratio: ${ratio}x, velocidad: ${speed} MB/s)"
      log "  💰 Ahorro: ${ahorro}% de espacio"

      # PASO 10: Guardar en el reporte
      VM_REPORT["$vm_name"]="${vm_name}|${backup_date}|${orig_size_gb}|${comp_size_gb}|${ratio}|${speed}|${formatted_duration}"

      # PASO 11: ELIMINAR EL ORIGINAL
      rm -f "$vmdk_file"
      log "  🗑️  Original eliminado (liberados ${orig_size_gb} GB)"

      return 0

    else
      log "  ❌ Archivo comprimido corrupto"
      rm -f "${vmdk_file}.tar.gz"
      return 1
    fi

  else
    log "  ❌ Error durante la compresión"
    return 1
  fi
}

# ==============================================================================
# MOSTRAR RESUMEN FINAL
# ==============================================================================

show_summary() {
  local total_time="$1"
  local total_processed="$2"
  local total_success="$3"
  local total_failed="$4"
  local total_skipped="$5"

  log ""
  log "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
  log "${GREEN}📊 RESUMEN FINAL${NC}"
  log "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
  log "  📅 Fecha: $(date '+%Y-%m-%d %H:%M:%S')"
  log "  📂 Directorio base: $BASE_DIR"
  log "  ⏱️  Tiempo total: $(format_time "$total_time")"
  log "  📦 Archivos procesados: $total_processed"
  log "  ✅ Exitosos: $total_success"
  log "  ❌ Fallidos: $total_failed"
  log "  ⏭️  Saltados: $total_skipped"

  if [ ${#VM_REPORT[@]} -gt 0 ]; then
    log ""
    log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${YELLOW}📈 DETALLE POR MÁQUINA${NC}"
    log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    for key in "${!VM_REPORT[@]}"; do
      IFS='|' read -r vm_name backup_date orig_size comp_size ratio speed duration <<<"${VM_REPORT[$key]}"
      log ""
      log "  🖥️  ${BLUE}$vm_name${NC}"
      log "     📁 Backup: $backup_date"
      log "     ├─ Original: $orig_size GB"
      log "     ├─ Comprimido: $comp_size GB"
      log "     ├─ Ratio: ${ratio}x"
      log "     ├─ Velocidad: ${speed} MB/s"
      log "     └─ Tiempo: $duration"
    done
  fi

  log ""
  log "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
  log "📁 Log principal: $LOG_FILE"
  log "${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
}

# ==============================================================================
# FUNCIÓN DE DESCOMPRESIÓN
# ==============================================================================

restore_vmdk() {
  local compressed_file="$1"

  if [ -z "$compressed_file" ]; then
    echo "❌ Uso: restore_vmdk \"archivo.tar.gz\""
    return 1
  fi

  if [ ! -f "$compressed_file" ]; then
    echo "❌ Archivo no encontrado: $compressed_file"
    return 1
  fi

  echo "📦 Restaurando: $compressed_file"
  echo "📊 Tamaño comprimido: $(du -h "$compressed_file" | cut -f1)"

  log "  🔍 Descomprimiendo con tar --sparse (preserva huecos)..."

  if pigz -d -c "$compressed_file" 2>/dev/null | $TAR -xS --sparse -f -; then
    echo "✅ Restauración exitosa (sparse preservado)"

    for file in *.vmdk; do
      [ -f "$file" ] || continue
      logical=$(ls -lh "$file" | awk '{print $5}')
      real=$(du -h "$file" | cut -f1)
      echo "📊 $file: lógico=$logical, real=$real"
      if [ "$logical" != "$real" ]; then
        echo "   ✅ Sparsidad preservada!"
      fi
    done
    return 0
  fi

  if pigz -dc "$compressed_file" | $TAR -xpf - 2>/dev/null; then
    echo "✅ Restauración exitosa"
    return 0
  fi

  echo "❌ Error durante la restauración"
  return 1
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
  local start_total=$(date +%s.%N 2>/dev/null || date +%s)

  VM_REPORT=()

  TOTAL_PROCESSED=0
  TOTAL_SUCCESS=0
  TOTAL_FAILED=0
  TOTAL_SKIPPED=0

  log "${GREEN}🚀 Iniciando compresión de VMDK${NC}"
  log "📂 Directorio base: $BASE_DIR"
  log "🧵 Hilos de compresión: $NPROC cores"
  log "📊 Nivel de compresión: $COMPRESSION_LEVEL"
  log "💾 Espacio mínimo requerido: ${MIN_FREE_SPACE_GB}GB"
  log "📌 Método: tar --sparse + pigz (preserva sparse)"
  log "📌 Verificación: pigz -t"
  log "📌 Detección de uso: 4 mediciones con 5s (15s total)"
  log ""
  log "📋 El resumen se mostrará al finalizar"
  log ""

  find "$BASE_DIR" -type f -name "*-flat.vmdk" ! -name "*.gz" ! -name "*.tar.gz" 2>/dev/null | while IFS= read -r vmdk; do

    TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))

    log ""
    log "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "📄 Archivo #$TOTAL_PROCESSED: $(basename "$vmdk")"
    log "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    compress_vmdk "$vmdk"
    local result=$?

    if [ $result -eq 0 ]; then
      TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
    elif [ $result -eq 2 ]; then
      TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
    else
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi
  done

  local end_total=$(date +%s.%N 2>/dev/null || date +%s)
  local total_duration=$(echo "$end_total - $start_total" | bc 2>/dev/null)
  [ -z "$total_duration" ] && total_duration=0

  # Mostrar resumen (sin reporte separado)
  show_summary "$total_duration" "$TOTAL_PROCESSED" "$TOTAL_SUCCESS" "$TOTAL_FAILED" "$TOTAL_SKIPPED"

  if [ "$TOTAL_FAILED" -gt 0 ]; then
    log "${YELLOW}⚠️  $TOTAL_FAILED archivos fallaron. Revisa el log: $LOG_FILE${NC}"
    return 1
  else
    log "${GREEN}✅ Todos los archivos procesados exitosamente${NC}"
    log "📋 Log completo en: $LOG_FILE"
    return 0
  fi
}

# ==============================================================================
# COMPROBAR VERSIÓN DE TAR
# ==============================================================================

check_tar_version() {
  local min_version="1.29"
  local tar_bin="${1:-/usr/local/bin/tar}"

  if [ ! -x "$tar_bin" ]; then
    echo "❌ ERROR: No se encuentra el binario de tar en: $tar_bin"
    echo "   Asegúrate de tener instalado tar >= $min_version"
    echo "   Puedes instalarlo con: yum install -y tar2"
    exit 1
  fi

  local version=$($tar_bin --version 2>/dev/null | head -1 | awk '{print $NF}')

  if [ -z "$version" ]; then
    echo "❌ ERROR: No se pudo determinar la versión de tar"
    exit 1
  fi

  if [ "$(printf '%s\n' "$min_version" "$version" | sort -V | head -n1)" != "$min_version" ]; then
    echo "❌ ERROR: Versión de tar ($version) es menor que $min_version"
    echo "   La versión actual no soporta correctamente --sparse con archivos grandes"
    echo "   Instala una versión más reciente:"
    echo "     yum install -y tar2"
    echo "   O compila desde fuente:"
    echo "     wget https://ftp.gnu.org/gnu/tar/tar-1.34.tar.gz"
    exit 1
  fi

  echo "✅ Tar versión $version (>= $min_version) - OK"
  return 0
}

# ==============================================================================
# EJECUCIÓN DEL SCRIPT
# ==============================================================================

check_tar_version $(which tar)

main "$@"
