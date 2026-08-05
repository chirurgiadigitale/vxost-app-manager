# XAMPP

Sostituto nativo di `manager-osx.app` per XAMPP su macOS: un'app nella barra di
stato che avvia, ferma e sorveglia Apache, MySQL e ProFTPD.

Nasce da un problema concreto: il manager originale è un binario BitRock
InstallBuilder del 2018, distribuito solo per `i386`, `ppc` e `x86_64`. Il suo
launcher decide quale eseguibile lanciare leggendo `uname -p`, e su Apple
Silicon quel valore è `arm`, che non corrisponde a nessun ramo: l'app termina
con *"The current OS X version is not supported"*. Non è ristilizzabile perché
l'interfaccia è compilata dentro il binario, quindi è stata riscritta.

Nessuna dipendenza esterna, nessun framework di terze parti, nessuna richiesta
di rete. Binario arm64 nativo di circa 100 KB.

## Cosa fa

**Barra di stato** — tre barrette, una per servizio, colorate quando il
servizio è attivo e in solo contorno quando è fermo. Lo stato dell'intero
stack si legge senza aprire nulla.

**Pannello** — stato, PID e porte in ascolto di ogni servizio; avvio e arresto
singolo o complessivo; riavvio; ricarica del singolo servizio dal menu
contestuale sulla riga.

**Scorciatoie** — Dashboard, phpMyAdmin, `htdocs` nel Finder, visualizzatore
log.

**Log** — log di sistema e log per singolo virtual host, con filtro testuale e
aggiornamento automatico. Legge sempre e solo la coda del file: il `.err` di
MySQL può superare i 3 GB e caricarlo interamente bloccherebbe l'app.

**Altro** — abilitazione e disabilitazione SSL, controllo sicurezza, backup,
accesso rapido ai file di configurazione.

## Come rileva lo stato

Non usa i file PID: `var/mysql/<host>.pid` appartiene a `_mysql` con permessi
`rw-rw----` e un utente normale non può leggerlo, quindi MySQL risulterebbe
sempre fermo. Al suo posto:

| Informazione | Metodo | Perché |
| --- | --- | --- |
| Servizio attivo | `pgrep -f <percorso binario>` | funziona senza privilegi e il percorso pieno distingue l'httpd di XAMPP da un Apache di sistema |
| Porte configurate | lettura di `httpd.conf`, `httpd-ssl.conf`, `my.cnf`, `proftpd.conf` | riflette la configurazione reale, vhost compresi |
| Porte in ascolto | `connect()` su `127.0.0.1` | `lsof` da utente normale non vede i processi di `root` e `daemon`, un probe TCP sì |

## Privilegi

Avviare e fermare i servizi richiede root. L'app usa
`do shell script … with administrator privileges`, cioè il pannello password
nativo di macOS — lo stesso meccanismo del manager originale. Non modifica
`sudoers` e non installa helper privilegiati.

`security` e `backup` fanno domande interattive, quindi vengono aperti nel
Terminale invece che eseguiti in silenzio.

## Icona

L'icona è generata dal logo ufficiale XAMPP, lo stesso SVG usato dalla
dashboard, così app e web root mostrano lo stesso marchio.

`tools/make-icon.m` lo renderizza in tutte le dimensioni richieste da macOS,
dalla 16 px alla 1024 px. Le dimensioni non vengono ingrandite da un bitmap:
macOS carica l'SVG nativamente e ogni misura è disegnata dal vettore. Il
marchio è ritagliato dalla sagoma delle icone di sistema — una superellisse,
non un rettangolo con angoli circolari — con l'ombra applicata dai 64 px in su.

Si rigenera da sola quando il logo cambia, oppure con `make icon`.

## Requisiti

macOS 13 o successivo, Command Line Tools. Xcode non serve.

## Build

```sh
make          # compila in build/XAMPP.app
make icon     # rigenera l'icona dal logo
make run      # compila e avvia
make install  # copia in /Applications/XAMPP/
make clean
```

## Licenza

GNU GPL, gli stessi termini di XAMPP.
