# vmware-vmdk-compressor

Script Bash para comprimir discos `*-flat.vmdk` provenientes de respaldos de máquinas virtuales VMware ESXi, como los generados por herramientas como ghettoVCB.

El objetivo principal es reducir el espacio utilizado por respaldos VMDK manteniendo la información **sparse** del disco y evitando comprimir archivos que todavía estén siendo escritos por un proceso de backup.

# Sparse: el pequeño detalle que puede hacer una pesadilla tu backup

Cuando trabajamos con discos virtuales, especialmente VMDK, existe un concepto que parece bastante simple, pero que puede hacer una diferencia enorme en un respaldo: **Sparse**.

Un archivo *sparse* puede tener un tamaño lógico enorme, pero físicamente ocupar mucho menos espacio. Los bloques que están vacíos no necesitan existir realmente en el disco.

Por ejemplo, podemos tener un VMDK de 1 TB, pero si la máquina virtual solamente tiene 150 GB utilizados, no tiene mucho sentido guardar físicamente 1 TB de información cuando 850 GB son sólo aire.

Ahí entra Sparse.

## ¿Por qué es importante?

Cuando el respaldo está correctamente diseñado, los bloques vacíos pueden mantenerse como bloques vacíos durante todo el proceso.

Esto significa:

- Menos espacio utilizado para almacenar los respaldos.
- Menos datos que procesar.
- Menos datos que comprimir.
- Menos ancho de banda utilizado.
- Menor tiempo de respaldo.
- Menor tiempo de transferencia.
- Menor tiempo de restauración.

Si tenemos un disco virtual de 1 TB con solamente 150 GB utilizados, queremos que el backup trabaje con los datos reales y no que se dedique alegremente a mover 850 GB de ceros por la red.

## ¿Y cuál es el problema?

Que hacerlo correctamente no es tan fácil como parece.

No basta con que el archivo original sea Sparse. Tenemos que conseguir que **siga siendo Sparse durante todo el proceso de respaldo**.

Por ejemplo:

    VMDK → tar → compresión → transferencia → almacenamiento → extracción → VMDK

Cada una de esas etapas puede hacer las cosas bien... o puede convertir nuestro hermoso archivo Sparse en un archivo normal del tamaño completo.

Y cuando eso ocurre, podemos pasar de tener un VMDK que físicamente ocupa 150 GB, a tener un backup que ocupa 1 TB.

Excelente negocio. Para los vendedores de discos duros, claro.

## ¿Por qué no basta con comprimirlo?

Porque Sparse y compresión son dos cosas diferentes.

Un archivo lleno de ceros se comprime extraordinariamente bien. El problema es que para comprimir esos ceros primero hay que **leerlos y procesarlos**.

Eso significa que podemos estar leyendo, procesando, comprimiendo, transfiriendo y escribiendo cientos de gigabytes que realmente no contienen ninguna información útil.

El objetivo de un buen sistema de respaldo es evitar ese trabajo desde el principio.

Por eso hay que utilizar correctamente herramientas como `tar` y `pigz`, además de las opciones adecuadas para conservar los bloques Sparse.

Y todavía falta la parte más importante: **restaurar correctamente el Sparse**.

Porque un backup que ocupa poco espacio pero que después no permite reconstruir el VMDK correctamente no es un backup.

Es un archivo comprimido que nos mira con desprecio cuando llega el momento de recuperar la máquina.

## ¿Dónde ejecutar este script?

Está pensado para ser ejecutado en el servidor NFS donde guardas tus respaldos de VMware, por ejemplo, respaldos hechos con *ghettoVCB*

## Características del script.

- Busca automáticamente archivos `*-flat.vmdk` bajo un directorio base.
- Detecta backups que todavía están en ejecución antes de comenzar la compresión.
- Detecta archivos de lock utilizados por el proceso de backup.
- Comprueba que exista un espacio libre mínimo antes de iniciar cada compresión.
- Utiliza GNU `tar` con soporte `--sparse` para preservar los huecos de archivos sparse.
- Utiliza `pigz` para realizar la compresión gzip en paralelo.
- Utiliza todos los cores disponibles por defecto.
- Permite definir el nivel de compresión de `pigz`.
- Soporta nombres de archivos y directorios que contengan espacios.
- Verifica la integridad del archivo `.tar.gz` antes de eliminar el VMDK original.
- Si la verificación falla, elimina el archivo comprimido corrupto y conserva el VMDK original.
- Calcula tamaño real utilizado en disco y tamaño lógico del VMDK.
- Calcula ratio de compresión, porcentaje de ahorro, velocidad y tiempo de procesamiento.
- Genera un log general del proceso.
- Genera un reporte independiente con estadísticas de cada máquina y backup.
- Permite restaurar manualmente los VMDK preservando nuevamente la condición sparse.
- Puede utilizar `igzip` para verificar la integridad cuando está disponible, utilizando `pigz` como alternativa y `gzip` como último recurso.

## Funcionamiento

El script busca archivos con el patrón:

    *-flat.vmdk

dentro del directorio definido en `BASE_DIR`.

Por defecto:

    BASE_DIR="/storage/VMware/ProxyReverso"

Este valor debe modificarse según la ubicación donde se almacenan los backups de VMware.

Antes de comprimir un VMDK, el script realiza varias comprobaciones.

### 1. Archivo ya comprimido

Si existe:

    archivo-flat.vmdk.tar.gz

el archivo es omitido para evitar volver a comprimirlo.

### 2. Detección de backup en ejecución

El script comprueba si existen archivos de lock:

    .lock
    .backup.lock

También busca archivos:

    .backup_*

Si alguno de estos elementos está presente, el VMDK se considera en uso y se omite.

Además, el tamaño utilizado del archivo se mide cuatro veces, con intervalos de 5 segundos.

Si el tamaño cambia entre mediciones, el archivo se considera todavía en proceso de escritura.

En total, esta comprobación puede tardar aproximadamente 15 segundos.

### 3. Comprobación de espacio disponible

Antes de comprimir, se comprueba el espacio libre del filesystem.

La configuración por defecto requiere:

    MIN_FREE_SPACE_GB=50

Si hay menos espacio disponible, el archivo se omite.

## Compresión

La compresión se realiza utilizando:

    tar --sparse + pigz

El flujo utilizado es equivalente a:

    tar -cf - --sparse --hole-detection=seek archivo-flat.vmdk | pigz -p N -6 > archivo-flat.vmdk.tar.gz

Donde `N` corresponde al número de cores disponibles.

Por defecto:

    NPROC=$(nproc)
    COMPRESSION_LEVEL=6

El nivel de compresión puede cambiarse entre `1` y `9`.

- `1`: mayor velocidad, menor compresión.
- `6`: equilibrio entre velocidad y compresión.
- `9`: mayor compresión, menor velocidad.

## Preservación de archivos sparse

Una característica importante del script es el uso de:

    tar --sparse

y:

    --hole-detection=seek

Esto permite preservar los huecos de los archivos sparse durante el empaquetado.

El script utiliza `du` para diferenciar entre el espacio realmente utilizado en el filesystem y el tamaño lógico del VMDK.

Por ejemplo, un VMDK puede tener un tamaño lógico muy grande pero ocupar considerablemente menos espacio físico debido a los bloques sparse.

## Verificación de integridad

Después de generar el `.tar.gz`, el script verifica su integridad antes de eliminar el VMDK original.

El orden de preferencia es:

1. `igzip`
2. `pigz`
3. `gzip`

La verificación se realiza mediante:

    igzip -t archivo.tar.gz

o:

    pigz -t archivo.tar.gz

o:

    gzip -t archivo.tar.gz

Si la verificación es exitosa, se considera seguro eliminar el VMDK original.

Si la verificación falla:

- se elimina el `.tar.gz` generado;
- se conserva el VMDK original;
- el proceso registra el error.

## Eliminación del VMDK original

El VMDK original solamente se elimina después de completar correctamente la compresión y la verificación de integridad.

El archivo se elimina mediante:

    rm -f archivo-flat.vmdk

Esto permite recuperar inmediatamente el espacio utilizado por el VMDK una vez que el backup comprimido ha sido validado.

## Reportes

El script genera dos tipos de información.

### Log principal

Por defecto:

    /var/log/vmdk_compress.log

El log registra el proceso completo, incluyendo:

- archivos encontrados;
- archivos omitidos;
- detección de backups en ejecución;
- espacio disponible;
- inicio de compresión;
- tiempo de compresión;
- tamaño original;
- tamaño comprimido;
- ratio de compresión;
- velocidad;
- ahorro de espacio;
- errores.

### Reporte

Se genera un archivo con timestamp:

    /var/log/vmdk_compress_report_YYYYMMDD_HHMMSS.log

El reporte contiene estadísticas por máquina y backup.

Entre los datos registrados:

    VM
    Backup
    Tamaño original
    Tamaño comprimido
    Ratio de compresión
    Velocidad
    Tiempo
    Ahorro de espacio

## Restauración

El script incluye una función de restauración para archivos `.tar.gz`.

La restauración utiliza:

    pigz -d -c archivo.tar.gz | tar -xS --sparse -f -

También existe un fallback utilizando `gzip` si `pigz` no está disponible durante la restauración.

El uso de:

    tar -xS --sparse

permite volver a crear el archivo manteniendo sus características sparse.

Después de la restauración, el script compara el tamaño lógico y el espacio realmente utilizado para comprobar que la sparsidad haya sido preservada.

## Requisitos

El script está pensado para sistemas Linux utilizados como repositorios de backups VMware.

### Bash

El script requiere Bash.

Comprobar:

    bash --version

### GNU tar 1.29 o superior

Se requiere GNU `tar` versión **1.29 o superior**.

Comprobar:

    tar --version

El script realiza una comprobación de versión antes de iniciar el proceso.

La versión de `tar` debe soportar correctamente las opciones utilizadas para trabajar con archivos sparse.

### pigz

`pigz` es el componente utilizado para realizar la compresión gzip en paralelo.

Comprobar:

    pigz --version

El script utiliza:

    pigz -p N -6

donde `N` corresponde al número de procesadores utilizados.

### igzip — opcional

`igzip` no es obligatorio.

Cuando está instalado, el script lo utiliza como primera opción para verificar la integridad del archivo comprimido.

Comprobar:

    igzip --version

Si no está disponible, se utiliza `pigz` y posteriormente `gzip`.

### gzip

`gzip` se utiliza como alternativa para verificar la integridad cuando no están disponibles `igzip` ni `pigz`, y también como fallback durante la restauración.

Comprobar:

    gzip --version

### bc

`bc` se utiliza para realizar cálculos de:

- tamaños;
- ratios;
- porcentajes;
- velocidades;
- tiempos.

Comprobar:

    bc --version

### GNU coreutils

El script utiliza varias herramientas normalmente proporcionadas por GNU coreutils:

    awk
    basename
    cut
    date
    df
    dirname
    du
    echo
    find
    grep
    head
    ls
    numfmt
    rm
    sed
    sleep
    sort
    tee
    which
    nproc

## Comandos utilizados

Las principales herramientas externas utilizadas por el script son:

    bash
    tar
    pigz
    igzip
    gzip
    bc
    awk
    basename
    cut
    date
    df
    dirname
    du
    echo
    find
    grep
    head
    ls
    numfmt
    rm
    sed
    sleep
    sort
    tee
    which
    nproc

## Configuración

Las principales variables configurables se encuentran al comienzo del script:

    BASE_DIR="/storage/VMware/ProxyReverso"

    LOG_FILE="/var/log/vmdk_compress.log"

    NPROC=$(nproc 2>/dev/null || echo 4)

    COMPRESSION_LEVEL=6

    MIN_FREE_SPACE_GB=50

### Directorio de backups

Cambiar:

    BASE_DIR="/storage/VMware/ProxyReverso"

por el directorio donde se encuentran los backups VMware.

### Número de cores

Por defecto utiliza todos los cores disponibles:

    NPROC=$(nproc 2>/dev/null || echo 4)

Se puede limitar manualmente, por ejemplo:

    NPROC=8

Esto puede ser útil cuando el servidor también ejecuta otros servicios.

### Nivel de compresión

Por defecto:

    COMPRESSION_LEVEL=6

Para priorizar velocidad:

    COMPRESSION_LEVEL=1

Para priorizar compresión:

    COMPRESSION_LEVEL=9

### Espacio mínimo

Por defecto:

    MIN_FREE_SPACE_GB=50

Por ejemplo:

    MIN_FREE_SPACE_GB=100

requiere al menos 100 GB libres antes de iniciar una compresión.

## Uso

Dar permisos de ejecución:

    chmod +x vmware-vmdk-compressor.sh

Ejecutar:

    ./vmware-vmdk-compressor.sh

El script procesa automáticamente los archivos encontrados bajo `BASE_DIR`.

## Formato generado

Un archivo:

    VM-flat.vmdk

se convierte en:

    VM-flat.vmdk.tar.gz

Una vez verificada correctamente la integridad del archivo comprimido, el archivo:

    VM-flat.vmdk

es eliminado.

## Restauración manual

Para restaurar un backup comprimido manualmente:

    pigz -d -c archivo.tar.gz | tar -xS --sparse -f -

Esto debe ejecutarse en el directorio donde se desea restaurar el VMDK.

También es posible utilizar:

    gzip -d -c archivo.tar.gz | tar -xS --sparse -f -

si `pigz` no está disponible.

## Consideraciones

Este script está diseñado para trabajar sobre **respaldos de máquinas virtuales**, no sobre VMDK que estén siendo utilizados directamente por una máquina virtual en producción.

El script intenta evitar la compresión de backups que todavía están siendo generados mediante locks y comprobaciones de crecimiento del archivo.

La eliminación del VMDK original ocurre solamente después de verificar la integridad del archivo comprimido.

## Licencia

Agregar aquí la licencia que corresponda al repositorio.

---

**OrangeBox Labs**

Herramientas y scripts para administración de infraestructura VMware y Linux.
