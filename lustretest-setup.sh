#!/bin/bash
read -s -p "Storage root password: " password
echo
read -s -p "adm password: " adm_pass
echo
export SSHPASS="${password}"
for i in lustretest-mgs lustretest-ost0 lustretest-ost1
do 
	sshpass -e ssh root@$i "echo "Setting Up VM"; useradd -m -s /bin/bash adm_irfant; usermod -aG wheel adm_irfant; echo "${adm_pass}" | passwd adm_irfant --stdin;"
	sshpass -e ssh root@$i	'echo "adm_irfant ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/adm_irfant; sudo chmod 0440 /etc/sudoers.d/adm_irfant'
	sshpass -e ssh root@$i "hostnamectl set-hostname "${i}", "
	cat ~/.ssh/id_ed25519.pub | sshpass -e ssh -o StrictHostKeyChecking=no root@$i "mkdir -p /home/adm_irfant/.ssh && chmod 700 /home/adm_irfant/.ssh && cat >> /home/adm_irfant/.ssh/authorized_keys && chmod 600 /home/adm_irfant/.ssh/authorized_keys && chown -R adm_irfant:adm_irfant /home/adm_irfant/.ssh"
done
