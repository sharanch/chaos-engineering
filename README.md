# chaos-engineering


This is a proof of concept of how a HA database container works on a kubernetes cluster, i mostly meant this to be running on my local minikube cluster, but it can be adapted to any cloud managed kubernetes services like eks, gke or oke


main manifest is the postgress-cluster.yaml which is an "Cluster" kubernetes object, which using cnpg (cloud native postgress) controller, to setup master/slave pods, cnpg should be installed first before you apply this manifest. link to the cnpg is in the manifest itself, commented out.


well a huge thing about this is, most of the work is done by cnpg controller, it handles the dynamic pvc.