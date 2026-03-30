# TP2&3 — mTLS MQTT | Schems Kerdoncuff

**Cours :** Cybersécurité SCADA/IoT  
**Date :** Mars 2026

## Description

Script d'installation automatisé pour la mise en place du chiffrement **mTLS sur MQTT** avec OpenSSL et Mosquitto.  
Il génère une PKI complète et configure le broker en une seule commande.

## Utilisation
```bash
chmod +x install.sh
sudo ./install.sh
```

## Ce que fait le script

1. Génère une CA racine (RSA 2048)
2. Crée les clés et certificats broker + client
3. Signe les certificats avec la CA
4. Configure Mosquitto sur le port 8883 en mTLS
5. Vérifie la chaîne de confiance

## Démonstration

<!-- Screenshot 1 : exécution du script -->

<img width="1130" height="1043" alt="image" src="https://github.com/user-attachments/assets/6c4e0804-4b17-4238-ab10-8adb2b130431" />


<!-- Screenshot 2 : résultat final -->

<img width="1099" height="1007" alt="image" src="https://github.com/user-attachments/assets/ae3d1908-ecc4-417b-b3e4-d83cc4a850ea" />


<!-- Screenshot 3 : résultat final -->


<img width="674" height="597" alt="image" src="https://github.com/user-attachments/assets/345fa953-7ac7-4831-b941-f0023c433790" />


## Prérequis
```bash
sudo apt install openssl mosquitto mosquitto-clients
```
