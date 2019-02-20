#!/bin/bash
# A quick one-liner to yank old kernels in CentOS 7
# yum-utils could do this as well, but I couldn't use it sadly.
# 
# One-liner:
# for kernel in $(rpm -qa | grep kernel-3); do [[ "${kernel}" == "kernel-$(uname -r)" ]] && continue; yum remove -y ${kernel} $(sed s/kernel/kernel-devel/ <<< ${kernel}); done

 for kernel in $(rpm -qa | grep kernel-3); do
    [[ "${kernel}" == "kernel-$(uname -r)" ]] && continue
    yum remove -y ${kernel} $(sed s/kernel/kernel-devel/ <<< ${kernel})
done
