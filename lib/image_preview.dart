import 'dart:io';
import 'package:flutter/material.dart';

class ImagePreview extends StatelessWidget {
  const ImagePreview({
    Key? key,
    required this.imagePaths,
    required this.focusOnImage,
  }) : super(key: key);

  final List<String> imagePaths;
  final void Function(String) focusOnImage;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 300,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(
            color: Color.fromARGB(255, 203, 203, 203),
            blurRadius: 10,
            spreadRadius: 2,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: imagePaths.isEmpty
          ? const Center(
              child: Text(
                "No images selected",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : ListView.builder(
              scrollDirection: Axis.vertical,
              physics: const BouncingScrollPhysics(),
              itemCount: imagePaths.length,
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () {
                    focusOnImage(imagePaths[index]);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Image.file(
                      File(imagePaths[index]),
                      fit: BoxFit.contain,
                    ),
                  ),
                );
              },
            ),
    );
  }
}