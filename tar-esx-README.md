# tar-esx

GNU tar 1.35 compilado como binario estático para VMware ESXi 8.x.

Su objetivo es permitir la extracción de backups TAR que contienen archivos **Sparse**, especialmente VMDK Thin de VMware.

El `tar` incluido en ESXi está basado en BusyBox y puede fallar al extraer determinados formatos GNU Sparse:

    tar: unknown typeflag: 0x53

## Requisitos

- VMware ESXi 8.x x86_64
- Acceso como `root`
- `tar-esx`
- `gzip` o `pigz`

## Habilitar la ejecución

ESXi bloquea por defecto la ejecución de binarios que no están instalados mediante VIB.

Antes de utilizar `tar-esx`:

    localcli system settings advanced set -o /User/ExecInstalledOnly -i 0

Comprobar:

    localcli system settings advanced list -o /User/ExecInstalledOnly

Debe mostrar:

    Int Value: 0

Esto genera una **alerta de seguridad en vCenter**.

Una vez terminada la restauración, volver a habilitar inmediatamente:

    localcli system settings advanced set -o /User/ExecInstalledOnly -i 1

Y comprobar:

    localcli system settings advanced list -o /User/ExecInstalledOnly

Debe quedar:

    Int Value: 1

No dejar `ExecInstalledOnly` desactivado permanentemente.

## Instalar tar-esx

Copiar el binario al ESXi:

    scp tar-esx root@esx1:/tmp/tar-esx

Dar permisos:

    chmod 755 /tmp/tar-esx

Verificar:

    /tmp/tar-esx --version

## Extraer un TAR

Para un `.tar` sin compresión:

    /tmp/tar-esx -xpf backup.tar

## Extraer un TAR.GZ

No se recomienda utilizar directamente:

    /tmp/tar-esx -xzf backup.tar.gz

En ESXi puede aparecer:

    Cannot fork: Function not implemented

En su lugar, separar la descompresión de la extracción.

Con `gzip`:

    gzip -dc backup.tar.gz | /tmp/tar-esx -xpf -

Con `pigz`:

    pigz -dc backup.tar.gz | /tmp/tar-esx -xpf -

`pigz` permite utilizar múltiples cores durante la descompresión.

## Restaurar directamente a un datastore

Por ejemplo:

    pigz -dc backup.tar.gz | \
        /tmp/tar-esx -xpf - \
        -C /vmfs/volumes/datastore/VM/

## Restaurar desde Linux hacia ESXi

Si el backup está en un servidor Linux:

    pigz -dc backup.tar.gz | \
        ssh root@esx1 "/tmp/tar-esx -xpf - -C /vmfs/volumes/datastore/VM/"

De esta forma el backup permanece comprimido durante la transferencia y el VMDK se reconstruye directamente como Sparse en el datastore.

## Verificar el Sparse

Después de restaurar:

    ls -lh archivo.vmdk

    du -h archivo.vmdk

Un VMDK puede mostrar, por ejemplo:

    ls -lh
    500G

pero:

    du -h
    80G

Eso significa que el archivo tiene 500 GB de tamaño lógico, pero solamente utiliza unos 80 GB físicamente.

## Importante

`tar-esx` no reemplaza el `tar` original de ESXi.

Es una herramienta independiente para restauraciones de backups que requieren soporte GNU Sparse.

Cuando termines:

    rm -f /tmp/tar-esx

    localcli system settings advanced set -o /User/ExecInstalledOnly -i 1

**Y sí: acuérdate de volver a activar `ExecInstalledOnly`. El vCenter se va a acordar por ti.**

### Compilar tu `tar-esx`

El binario `tar-esx` se construye utilizando el **código fuente original de GNU tar 1.35**, sin modificaciones al código fuente. Pero si la paranoia está muy fuerte, puedes compilar tu mismo.

Para esta compilación utilizamos **CentOS 8 x86_64**, principalmente porque CentOS 8 utiliza **glibc 2.28**, una versión que también está presente en VMware ESXi 8.0.3.

Aunque el resultado final es un binario estáticamente enlazado, utilizar una plataforma de compilación con una versión de glibc cercana a la del sistema donde se ejecutará reduce las diferencias entre el entorno de compilación y ESXi y hace que el proceso sea más fácil de reproducir.

Esto **no significa que CentOS 8 sea un requisito absoluto**.

También es posible compilar `tar-esx` en distribuciones más nuevas como **AlmaLinux 9 o AlmaLinux 10**, siempre que se genere correctamente un binario estático y se compruebe posteriormente su ejecución en el ESXi objetivo.

Sin embargo, al utilizar una distribución más nueva se está compilando con una toolchain y librerías más modernas. Aunque el binario sea estático, no conviene asumir que cualquier binario generado en cualquier distribución será automáticamente compatible con ESXi.

Por eso, para este proyecto utilizamos CentOS 8 como entorno de referencia: proporciona una base cercana al entorno de ESXi 8 y permite reproducir exactamente el binario que estamos utilizando.

#### Requisitos

Servidor de compilación:

- CentOS 8 x86_64
- GCC
- Make
- Herramientas de desarrollo
- Código fuente original de GNU tar 1.35

Instalar las herramientas de compilación:

    dnf groupinstall -y "Development Tools"

Descargar GNU tar 1.35:

    wget https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz

Descomprimir:

    tar -xf tar-1.35.tar.xz

Entrar al directorio:

    cd tar-1.35

Configurar una compilación estática:

    ./configure LDFLAGS="-static"

Compilar:

    make -j$(nproc)

El binario generado estará en:

    src/tar

Comprobar que sea estático:

    file src/tar

Debe indicar algo similar a:

    ELF 64-bit LSB executable, x86-64, ... statically linked

Comprobar que no tenga dependencias dinámicas:

    ldd src/tar

El resultado esperado es:

    not a dynamic executable

Comprobar la versión:

    ./src/tar --version

Debe mostrar:

    tar (GNU tar) 1.35

Finalmente:

    cp src/tar tar-esx

Y verificar:

    file tar-esx
    ldd tar-esx
    ./tar-esx --version

El resultado es un único binario estático que puede copiarse al ESXi:

    scp tar-esx root@esx1:/tmp/tar-esx

### ¿Por qué no compilarlo directamente en AlmaLinux 9 o 10?

Se puede.

De hecho, para mantener un entorno de compilación moderno y soportado, AlmaLinux 9 o 10 puede ser una mejor opción a largo plazo. Sin embargo, para este proyecto preferimos inicialmente CentOS 8 porque su glibc 2.28 es cercana a la utilizada por ESXi 8.0.3 y ya comprobamos que el binario resultante funciona correctamente en el hypervisor.

Si se utiliza AlmaLinux 9, AlmaLinux 10 u otra distribución más moderna, recomendamos comprobar el resultado directamente en el ESXi donde se utilizará:

    file tar-esx
    ldd tar-esx
    /tmp/tar-esx --version

Y posteriormente realizar una prueba real de extracción de un TAR que contenga un archivo Sparse.

La compatibilidad final no se debe asumir solamente porque `file` indique `statically linked`. **La prueba definitiva es ejecutar el binario en el ESXi objetivo y comprobar que GNU tar puede crear o restaurar correctamente los archivos Sparse.**

No se modifica el código fuente de GNU tar. El proyecto utiliza el código fuente oficial de GNU tar 1.35 y únicamente lo compila de forma estática para obtener un binario independiente que pueda ejecutarse en ESXi.
