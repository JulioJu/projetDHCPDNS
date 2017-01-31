# Projet de réseau

## Énonce du projet

« Le but de ce projet et de développer et mettre en place des scripts Perl permettant la génération automatique des fichiers de configuration DHCP et DNS, lors de l'ajout, la modification ou de la suppression d'un hôte, à partir d'informations stockées dans une base de données MySQL. »
Le projet sera réalisé sur Marionnet.

## Choix de conception
### Explications du fonctionnement

**Contrairement à des solutions classiques, on ne modifie pas manuellement les fichiers de configuration, mais on le fait à travers des outils dédiés.**

Les fichiers modifiés par ces programmes sont les fichiers dhcpd.leases, db.imss.org, db.imss.org.inv.  Des fichiers temporaires db.imss.org.jnl et db.imss.org.inv.jnl sont créés par ddns et nsupdate.

* ddns. Ce service permet au serveur dhcpd de mettre à jour dynamiquement le serveur dns. Aucune action n'est requise pour cela.
* `rndc freeze && rndc flush` permet de détruire les fichiers journaux .jnl, de mettre à jour le fichier de base de données du service bind9, cependant il n'y a pas besoin de l'exécuter pour que les modifications prennent effet. Une fois que le client a demandé une nouvelle adresse ip (`dhclient interface -v`), même si le fichier db.imss.org et db.imss.org.inv ne sont pas à jours, le client répondra avec son nouveau nom DNS et sa nouvelle adresse ip. Pour ce TP, j'ai utilisé rndc qu'à des fins de démonstration, en environnement de production il ne serait pas utile puisqu'on n'a pas à consulter les fichier `db.imss.org` et `db.imss.org.inv`. La fonction rndc pourrait être supprimée en milieu de production, sachant qu'en plus elle ne fonctionne pas systématiquement (il faut que l'hôte demande sa nouvelle adresse avant que rndc soit exécutée).
* `nsupdate` est utilisée pour supprimer des enregistrements dns A, PTR et TXT.  Il est utilisé lors de la destruction d'un hôte, et lors de l'attribution d'un nouveau hostname et d'une nouvelle adresse ip afin de supprimer les anciennes références.
* `omshell` est utilisé pour mettre à jour le fichier dhcpd.leases. Il permet de créer un host avec une ip et un hostname fixe, et de le supprimer. La modification des adresses IP ou de l'hostname passe par une suppression, puis une création de l'hôte.
* J'ai implémenté une fonction qui permet de transformer toutes les leases actives en host avec ip-fix et hostname. Cette fonction nécessite que le fichier dhcpd.conf ait l'option « allow unknown-clients ». Cette option est dangereuse, car elle fournit une route et une adresse ip à toute machine. Cependant, elle peut s'avérer utile. Elle peut-être par exemple exécutée le matin à 07 heure, quand on est certain que personne d'autre que l'administrateur système n'est présent dans les bâtiments, et que seul les machines que l'on souhaite intégrer sont allumées. Cela permet ainsi d'éviter d'intégrer de matières fastidieuses de nouveaux hôtes. Cette fonction est à tester.

### Avantages
* Absence de redémarrage de bind9 et dhcpd, les modifications se font à chaud
* Mises à jour sécurisées par des clés partagées TSIG (on peut les encoder en sha)
* Utilisation d'outils dédiés à ce genre de manipulation
* Robustesse de la procédure
* Absence de risque de corruption des fichiers de configuration bind9 et dhcp pour cause de mauvaise implémentation du code (ce sont des utilitaires conçus pour qui manipulent ces fichiers)

### Inconvénients

* Utilisations de logiciels tiers ne disposant pas de tutoriels simples. Il est parfois nécessaire de se référer au listes de diffusion de l'isc.
* Interdiction de la modification manuelle de la cache DNS (db.imss.org(.inv)) (on peut cependant recourir à `rndc freeze` et `rndc thaw`
* Sous la simplicité apparente, certaine complexité de la manipulation des différents outils fournis par l'ISC, et dans l’interaction entre les différents composants
* Augmentation du nombre d'utilitaires : augmentation des sources de bugs, et de la difficulté de trouver celui qui ne fonctionne pas.
* Si une modification avec Omshell échoue, cet utilitaire envoie ses informations sur STDOUT et ne se termine pas avec un code d'erreur. Pour pallier à ce problème, j'ai regardé tous les messages qui semblaient indiquer une erreur. Si omshell imprime sur la sortie standard un message qui contient une information d'erreur, le script se termine. Cette manière de faire est dangereuse, si lors d'une mise à jour de dhcpd les messages changent, la compatibilité sera rompue.

## Environnement de développement

La machine supportant le script et la base de données est la machine hôte, dans mon cas il s'agissait d'Archlinux. Vu qu'elle utilise des utilitaires fournis par bind9, un serveur dns doit être installé sur la machine hôte, sans être ni configuré, ni démarré. Sous Archlinux, il faut le paquet bind-tools.

Les machines invitées sont toutes des machines Debian Wheezy fournies par Marionnet trunk. Il est possible (voire probable) que se script ne fonctionne pas si le server DHCPD et bind9 est une Debian Lenny. Malheureusement, il semblerait que la version utilisée par le nsupdate d'Archlinux ne soit pas compatible avec la version nsupdate de Debian Wheezy, j'ai du recourir à un script envoyée et exécutée sur la machine supportant le dns primaire grâce à SSH (ce qui me paraît moins propre). 

J'ai choisis Debian Wheezy par rapport à Debian Lenny car il intègre iproute2 (j'ai lu qu'il ne fallait plus utiliser net-utils - plus lent, plus à jour, etc…), et qu'il risquait moins de rencontrer des problèmes de compatibilité dans son interaction avec ArchLinux.

Faire supporter la base de donnée par l'hôte présente l'avantage d'utiliser toutes les ressources de l'hôte (Terminator, Neovim, ActivePerl, …). Cependant, cette solution a un grand désavantage, elle oblige à reconfigurer certains fichiers à chaque démarrage.

## Configuration 

*Voir les exemples de fichier de configuration ci-joint.*
* Le fichier dhcpd.conf et les fichiers named.conf\* doivent être correctement configurés. Il doivent notamment supporter les mises à jour par ddns, omshell, et ils doivent avoir les bonnes clés TSIG.
* Les en-têtes du script doivent bien être mises à jour, et notamment les adresses ip des serveurs. Si adm est la machine hôte, cette adresse peut être trouvée dans la table de routage de l'hôte (utiliser ncat -l 2000 pour chercher le bon invité, ou démarrer progressivement les machines).
* Dans ns1, le fichier  /etc/bind/named.conf.options, section « controls » doit être bien à jour.
    * L'adresse 172.23.0.4 représente l'adresse ip du server bind9 (ns1). 
    * L'adresse 172.23.0.254 doit être mise à jour avec l'adresse ip de l'interface sur laquelle écoute ns1. Généralement, il s'agit de l'adresse ip de eth0.  Cependant, si adm est la machine hôte, on trouve cette adresse en tapant `echo $DISPLAY`. Dans Marionnet, une fois configurée, je n'ai jamais eu besoin de changer cette adresse, l'adresse ip de cette interface semble unique.
 ```
controls { 
    inet 172.23.0.4 port 953 allow { 127.0.0.1; 172.23.0.254; }  
    keys { ns-imss-org_rndc-key; }; 
}; 
```
* La base mysql doit être configurée avec 
```
# CREATE TABLE `tpreseau2`.`network` ( `mac` VARCHAR(17) NOT NULL , `ip` VARCHAR(3) NOT NULL , `hostname` VARCHAR(40) NOT NULL , PRIMARY KEY (`mac`(17)), UNIQUE (`ip`(3)), UNIQUE (`hostname`(20))) ENGINE = InnoDB;
```

* Le script ne doit pas être lisible, seulement exécutable. Il existe des outils pour sécuriser ces fichiers contre des attaques.

## Utilisation

* Exécuter le script, et choisir parmi une des 5 actions possibles. 
* Arguments de la ligne de commande :
    * for create a new host : ./$0 --action=create --mac=new_mac_adress --ipnew=ip_v4_address --hostname=name_of_host
    * for change an ip host : ./$0 --action=changeip --mac=mac_adress_host_already_saved --ipnew=ip_v4_address
    * for change a hostname : ./$0 --action=changehostname --mac=mac_adress_host_already_saved --ipnew=ip_v4_address
    * for add new actives leases (if dhcpd.conf have « allow unknown-clients ») : ./$0 --action=addfromdhcpdleasesfile (note tested).
    * Note : For --action=changeip, --hostname is not relevant and for --action=changehostname --ipnew is not relevant so not used

* Ce script peut-être testé avec le fichier pourTester.bash

## Pistes d'amélioration

* Créer un mode non interactif, ou mode bash (utile pour modifier à la chaîne une série d'hôtes)
* En mode interactif, à chaque fois que que l'on rentre dans la boucle principale, recharger la base Mysql. Cela permettra de ne plus utiliser les subroutines `delayOldHostInArray` et `pushNewHostInArray` (avec ses multiples passage de tableaux par référence). Cela permettra de simplifier le code, et d'être sûr que l'on est à jour de la base mysql.
* Dans la base mysql, ne pas utiliser l'adresse mac comme clé primaire, mais des indices.
* Travailler avec des adresses ip entières, afin de pouvoir gérer plusieurs réseaux, et non avec seulement le numéro de l'host (ex. 230).
* Penser qu'on peut avoir des centaines d'adresse IP, modifier le script en conséquence. Pour la modification d'un hôte, il faudrait d'abord afficher la liste des hôtes, sélectionner l'hôte, et effectuer les modifications désirées.
* Améliorer la sécurité ssh.


## Bugs connus
* La fonction deleteOldHostInArray semble non fonctionnelle. Quand on détruit un hôte, il reste dans les tableau @macUsed @ipUsed, et @hostnameUsed. Il doit probablement avoir un problème de passage par référence et par valeur des array. Ce problème sera résolue si à chaque fois qu'une action est terminée, on actualise le contenu de ces tableaux avec la base MySQL, et qu'on détruit cette fonction

## Voir également 

* le fichier de test
* la fichier .odt (pas tout à fait à jour)
