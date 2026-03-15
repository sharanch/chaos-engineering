#The below is for dyanamicpv-postgress.yaml

kubectl exec -i pg-0 -- psql -U postgres <<EOF
CREATE TABLE k8s_test (message TEXT);
INSERT INTO k8s_test VALUES ('Confirmed: Storage is persistent!');
SELECT * FROM k8s_test;
EOF
CREATE TABLE
INSERT 0 1

kubectl get pods

kubectl exec -i pg-0 -- psql -U postgres -c "SELECT * FROM k8s_test;"


#The below is for postgress-cluster.yaml

export DB_PASSWORD=$(kubectl get secret my-pg-cluster-app -o jsonpath="{.data.password}" | base64 --decode)

kubectl exec -it my-pg-cluster-1 -- psql -h 127.0.0.1 -U app_user -d app_db

CREATE TABLE k8s_sharan_test (id serial PRIMARY KEY, val TEXT);
INSERT INTO k8s_sharan_test (val) VALUES ('Success from Sharan! is not success');
SELECT * FROM k8s_sharan_test;

kubectl exec -it my-pg-cluster-3 -- psql -h 127.0.0.1 -U app_user -d app_db -c "SELECT * FROM k8s_sharan_test;"