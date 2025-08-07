package webhook

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func convertV1ToV2(v1Obj *ExampleV1) *ExampleV2 {
	return &ExampleV2{
		TypeMeta:   metav1.TypeMeta{APIVersion: "conversion.example.com/v2", Kind: "Example"},
		ObjectMeta: v1Obj.ObjectMeta,
		Spec: ExampleV2Spec{
			Field1: v1Obj.Spec.Field1,
			Field2: "default-v2-value", // Add default for new field
		},
		Status: v1Obj.Status,
	}
}

func convertV2ToV1(v2Obj *ExampleV2) *ExampleV1 {
	return &ExampleV1{
		TypeMeta:   metav1.TypeMeta{APIVersion: "conversion.example.com/v1", Kind: "Example"},
		ObjectMeta: v2Obj.ObjectMeta,
		Spec: ExampleV1Spec{
			Field1: v2Obj.Spec.Field1,
			// Field2 is dropped when converting to v1
		},
		Status: v2Obj.Status,
	}
}
