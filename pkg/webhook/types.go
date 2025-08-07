package webhook

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

type ExampleV1 struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              ExampleV1Spec `json:"spec,omitempty"`
	Status            interface{}   `json:"status,omitempty"`
}

type ExampleV1Spec struct {
	Field1 string `json:"field1,omitempty"`
}

// DeepCopyObject implements runtime.Object interface
func (e *ExampleV1) DeepCopyObject() runtime.Object {
	if e == nil {
		return nil
	}
	out := &ExampleV1{}
	*out = *e
	out.TypeMeta = e.TypeMeta
	e.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	out.Spec = ExampleV1Spec{
		Field1: e.Spec.Field1,
	}
	out.Status = e.Status
	return out
}

type ExampleV2 struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              ExampleV2Spec `json:"spec,omitempty"`
	Status            interface{}   `json:"status,omitempty"`
}

type ExampleV2Spec struct {
	Field1 string `json:"field1,omitempty"`
	Field2 string `json:"field2,omitempty"`
}

// DeepCopyObject implements runtime.Object interface
func (e *ExampleV2) DeepCopyObject() runtime.Object {
	if e == nil {
		return nil
	}
	out := &ExampleV2{}
	*out = *e
	out.TypeMeta = e.TypeMeta
	e.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	out.Spec = ExampleV2Spec{
		Field1: e.Spec.Field1,
		Field2: e.Spec.Field2,
	}
	out.Status = e.Status
	return out
}
