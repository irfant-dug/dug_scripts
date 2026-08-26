#!/bin/bash
read -s -p "Storage root password: " password
echo
read -s -p "adm password: " adm_pass
echo
export SSHPASS="${password}"
for i in lustretest-mgs lustretest-ost0 lustretest-ost1 lustretest-ost2 lustretest-ost3 lustretest-ost4 lustretest-ost5 lustretest-ost6 lustretest-ost7 lustretest-ost8 lustretest-ost9 lustretest-ost10 lustretest-ost11 lustretest-ost12 lustretest-ost13 lustretest-ost14 lustretest-ost15 lustretest-ost16 lustretest-ost17 lustretest-ost18 lustretest-ost19 lustretest-ost20 lustretest-ost21 lustretest-ost22 lustretest-ost23
do 
	sshpass -e ssh root@$i "echo "Setting Up VM"; useradd -u 4530 -m -s /bin/bash adm_irfant; usermod -aG wheel adm_irfant; echo "${adm_pass}" | passwd adm_irfant --stdin;"
	sshpass -e ssh root@$i	'echo "adm_irfant ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/adm_irfant; sudo chmod 0440 /etc/sudoers.d/adm_irfant'
	sshpass -e ssh root@$i "hostnamectl set-hostname "${i}", "
	cat ~/.ssh/id_ed25519.pub | sshpass -e ssh -o StrictHostKeyChecking=no root@$i "mkdir -p /home/adm_irfant/.ssh && chmod 700 /home/adm_irfant/.ssh && cat >> /home/adm_irfant/.ssh/authorized_keys && chmod 600 /home/adm_irfant/.ssh/authorized_keys && chown -R adm_irfant:adm_irfant /home/adm_irfant/.ssh"
done
