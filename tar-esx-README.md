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
